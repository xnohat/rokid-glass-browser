package com.rokid.rokid_browser_glasses

import android.bluetooth.BluetoothManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.media.AudioManager
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.ViewGroup
import android.view.WindowManager
import android.view.inputmethod.InputMethodManager
import android.webkit.WebView
import androidx.webkit.WebSettingsCompat
import androidx.webkit.WebViewFeature
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject

class MainActivity : FlutterActivity() {

    private val EVENT_CHANNEL  = "com.snorlytics.browser_glasses/events"
    private val METHOD_CHANNEL = "com.snorlytics.browser_glasses/methods"

    private var btClient: BrowserBleServer? = null
    @Volatile private var eventSink: EventChannel.EventSink? = null
    private val mainHandler = Handler(Looper.getMainLooper())
    private lateinit var pixelCopyCapture: PixelCopyCapture
    private var passthroughView: android.view.View? = null
    private var cursorView: android.view.View? = null
    private var userDimLevel = 0.55f // last brightness-dim chosen from the phone
    private var currentZoomFactor = 1f // current WebView pinch-zoom scale
    // The touchpad emits KEYCODE_BACK twice per physical double-tap (a few ms
    // apart). Dedup so one gesture = one browser-back, not two history jumps.
    private var lastBackMs = 0L
    private var cursorDotNormal: android.graphics.drawable.GradientDrawable? = null
    private var cursorDotDrag: android.graphics.drawable.GradientDrawable? = null
    private var cursorBroughtToFront = false
    private var cursorWvOffsetY = -1f
    private var cursorOffsetFrame = 0

    // Rokid temple button: system broadcasts (no permission needed). Measured
    // 2026-09-07: press = BUTTON_UP, hold ~1s = BUTTON_LONG_PRESS; firmware does
    // not distinguish double/triple press. While this app is in front we ask the
    // Rokid assist server to disable its own photo/video actions and restore
    // them when we leave (same mechanism as rokid-zoom-in-camera).
    private val buttonReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            val action = when (intent.action) {
                "com.android.action.ACTION_SPRITE_BUTTON_UP" -> "hw_button_up"
                "com.android.action.ACTION_SPRITE_BUTTON_LONG_PRESS" -> "hw_button_long"
                else -> return
            }
            val json = JSONObject().put("type", "browser_cmd").put("action", action).toString()
            runOnUiThread { eventSink?.success(json) }
        }
    }
    private var buttonReceiverRegistered = false
    @Volatile private var asrStop = false
    private var asrThread: Thread? = null
    @Volatile private var ttsTrack: android.media.AudioTrack? = null
    private var asrFile: java.io.File? = null

    private fun setRokidButtonFunctions(shortPress: String, longPress: String) {
        try {
            val intent = Intent("com.rokid.os.master.assist.server.cmd")
                .setPackage("com.rokid.os.sprite.assistserver")
            intent.putExtra("cmd_type", "setting_change")
            intent.putExtra("value",
                "[{\"key\":\"settings_interaction_shortPressFun\",\"value\":\"" + shortPress +
                "\"},{\"key\":\"settings_interaction_longPressFun\",\"value\":\"" + longPress + "\"}]")
            sendBroadcast(intent)
        } catch (_: Exception) {}
    }

    /** RV101 keeps its own Wi-Fi preference; without it SpriteWifiService turns
     *  Wi-Fi back off after a reboot (learned from ksuzukigh/rokid-wifi-on). */
    private fun ensureWifiOn() {
        try {
            val intent = Intent("com.rokid.os.master.assist.server.cmd")
                .setPackage("com.rokid.os.sprite.assistserver")
            intent.putExtra("cmd_type", "setting_change")
            intent.putExtra("value", "[{\"key\":\"settings_wifi_enable\",\"value\":\"true\"}]")
            sendBroadcast(intent)
        } catch (_: Exception) {}
        try {
            val wm = wifiManager()
            @Suppress("DEPRECATION")
            if (!wm.isWifiEnabled) wm.setWifiEnabled(true)
        } catch (_: Exception) {}
        mainHandler.postDelayed({ sendWifiState() }, 1500)
    }

    private fun claimHardwareButton() {
        if (!buttonReceiverRegistered) {
            val f = IntentFilter().apply {
                addAction("com.android.action.ACTION_SPRITE_BUTTON_UP")
                addAction("com.android.action.ACTION_SPRITE_BUTTON_LONG_PRESS")
            }
            try { registerReceiver(buttonReceiver, f); buttonReceiverRegistered = true } catch (_: Exception) {}
        }
        setRokidButtonFunctions("none", "none")
    }

    private fun releaseHardwareButton() {
        if (buttonReceiverRegistered) {
            try { unregisterReceiver(buttonReceiver) } catch (_: Exception) {}
            buttonReceiverRegistered = false
        }
        setRokidButtonFunctions("picture", "video")
    }

    private val wifiReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (intent.action == WifiManager.WIFI_STATE_CHANGED_ACTION ||
                intent.action == WifiManager.NETWORK_STATE_CHANGED_ACTION) {
                mainHandler.postDelayed({ sendWifiState() }, 500)
            }
        }
    }

    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        super.onCreate(savedInstanceState)
        pixelCopyCapture = PixelCopyCapture(window, mainHandler)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        val filter = IntentFilter().apply {
            addAction(WifiManager.WIFI_STATE_CHANGED_ACTION)
            addAction(WifiManager.NETWORK_STATE_CHANGED_ACTION)
        }
        registerReceiver(wifiReceiver, filter)
    }

    private fun findWebView(v: android.view.View): WebView? {
        if (v is WebView) return v
        if (v is ViewGroup) {
            for (i in 0 until v.childCount) {
                findWebView(v.getChildAt(i))?.let { return it }
            }
        }
        return null
    }

    // Returns the YouTube/custom fullscreen view added by webview_flutter's onShowCustomView().
    // System decor children (statusBarBackground, navigationBarBackground, the content
    // FrameLayout, etc.) all have resource IDs.  The custom view is added without an ID
    // (id == NO_ID) and covers most of the screen — we use both criteria to avoid false
    // positives from our own cursor/passthrough views (skipped by identity check first).
    private fun findFullscreenView(): android.view.View? {
        val root = window.decorView as android.view.ViewGroup
        val screenW = resources.displayMetrics.widthPixels
        val screenH = resources.displayMetrics.heightPixels
        for (i in root.childCount - 1 downTo 0) {
            val child = root.getChildAt(i)
            if (child === cursorView || child === passthroughView) continue
            if (child.id != android.view.View.NO_ID) continue  // skip all system/framework views
            if (child.visibility != android.view.View.VISIBLE) continue
            if (child.width < screenW / 2 || child.height < screenH / 2) continue
            return child
        }
        return null
    }

    /// A non-interactive black overlay above the WebView that caps how much light
    /// the display emits, plus a lowered screen brightness. This is the reliable
    /// anti-overheat layer for any page (Facebook feed, iframes, canvas) that CSS
    /// dark mode can't fully darken. alpha 0 = off.
    /// On the Rokid waveguide a translucent black View does NOT reduce emitted
    /// light (it only muddies the content). The one thing that genuinely cuts light
    /// and heat is lowering the actual panel brightness. So this only sets
    /// screenBrightness — no overlay View. alpha here is reused as a "dim amount".
    private fun setScreenDim(alpha: Float) {
        runOnUiThread {
            val a = alpha.coerceIn(0f, 1f)
            window.attributes = window.attributes.apply {
                screenBrightness = if (a <= 0f)
                    WindowManager.LayoutParams.BRIGHTNESS_OVERRIDE_NONE
                else
                    // Keep a 4% floor so the panel never goes fully black/unusable.
                    (1f - a).coerceIn(0.04f, 1f)
            }
        }
    }

    @Suppress("DEPRECATION")
    private fun applyForceDark(wv: WebView, enable: Boolean) {
        // Dark mode = respect the SITE's own dark theme only. We do NOT algorithmically
        // recolor pages that don't ship a dark theme (that was the "fake" dark mode
        // that made every site look washed-out). Sites with prefers-color-scheme
        // support switch; sites without stay in their original colors.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            // Algorithmic darkening = the WebView inventing a dark theme. Keep it OFF.
            // On API 33+ the WebView honors prefers-color-scheme from the app's night
            // uiMode, so leave algorithmic darkening disabled unconditionally.
            if (WebViewFeature.isFeatureSupported(WebViewFeature.ALGORITHMIC_DARKENING)) {
                WebSettingsCompat.setAlgorithmicDarkeningAllowed(wv.settings, false)
            }
        } else {
            if (WebViewFeature.isFeatureSupported(WebViewFeature.FORCE_DARK)) {
                WebSettingsCompat.setForceDark(
                    wv.settings,
                    if (enable) WebSettingsCompat.FORCE_DARK_ON else WebSettingsCompat.FORCE_DARK_OFF
                )
            }
            // WEB_THEME_DARKENING_ONLY = apply the site's OWN dark theme when it has
            // one (via prefers-color-scheme), and leave sites without a dark theme
            // untouched. This is the opposite of USER_AGENT_DARKENING_ONLY, which
            // force-darkened every page. No more simulated/fake dark mode.
            if (WebViewFeature.isFeatureSupported(WebViewFeature.FORCE_DARK_STRATEGY)) {
                WebSettingsCompat.setForceDarkStrategy(
                    wv.settings,
                    WebSettingsCompat.DARK_STRATEGY_WEB_THEME_DARKENING_ONLY
                )
            }
        }
    }

    private fun wifiManager() =
        applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager

    @Suppress("DEPRECATION")
    private fun buildWifiJson(): String {
        val wm = wifiManager()
        val enabled = wm.isWifiEnabled
        val info = wm.connectionInfo
        val ssid = if (enabled && info != null && info.networkId != -1)
            info.ssid.trim('"') else ""
        val rssi = if (ssid.isNotEmpty()) info?.rssi ?: 0 else 0
        return JSONObject()
            .put("type", "wifi_state")
            .put("enabled", enabled)
            .put("ssid", ssid)
            .put("rssi", rssi)
            .toString()
    }

    @Suppress("DEPRECATION")
    private fun connectToWifi(ssid: String, password: String): Boolean {
        if (ssid.isEmpty()) return false
        val wm = wifiManager()
        if (!wm.isWifiEnabled) {
            wm.setWifiEnabled(true)
            Thread.sleep(1000)
        }
        val config = android.net.wifi.WifiConfiguration().apply {
            SSID = "\"$ssid\""
            if (password.isEmpty()) {
                allowedKeyManagement.set(android.net.wifi.WifiConfiguration.KeyMgmt.NONE)
            } else {
                preSharedKey = "\"$password\""
                allowedKeyManagement.set(android.net.wifi.WifiConfiguration.KeyMgmt.WPA_PSK)
            }
        }
        val netId = wm.addNetwork(config)
        if (netId == -1) return false
        wm.disconnect()
        wm.enableNetwork(netId, true)
        wm.reconnect()
        return true
    }

    private fun sendWifiState() {
        val json = buildWifiJson()
        btClient?.send(json)
        runOnUiThread { eventSink?.success(json) }
    }

    override fun onStart() {
        super.onStart()
        pixelCopyCapture.start()
        // Microphone for in-page voice search (YouTube/Google "search by voice").
        if (androidx.core.content.ContextCompat.checkSelfPermission(this, android.Manifest.permission.RECORD_AUDIO) !=
            android.content.pm.PackageManager.PERMISSION_GRANTED) {
            requestPermissions(arrayOf(android.Manifest.permission.RECORD_AUDIO), 201)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val needed = arrayOf(
                android.Manifest.permission.BLUETOOTH_CONNECT,
                android.Manifest.permission.BLUETOOTH_SCAN
            ).filter {
                androidx.core.content.ContextCompat.checkSelfPermission(this, it) !=
                    android.content.pm.PackageManager.PERMISSION_GRANTED
            }
            if (needed.isNotEmpty()) requestPermissions(needed.toTypedArray(), 200)
        }
    }

    override fun onResume() {
        super.onResume()
        ensureWifiOn()
        claimHardwareButton()
    }

    override fun onPause() {
        releaseHardwareButton()
        super.onPause()
    }

    override fun onStop() {
        pixelCopyCapture.stop()
        super.onStop()
    }

    override fun onDestroy() {
        releaseHardwareButton()
        pixelCopyCapture.shutdown()
        try { unregisterReceiver(wifiReceiver) } catch (_: Exception) {}
        passthroughView?.let { v ->
            try { (window.decorView as? android.view.ViewGroup)?.removeView(v) } catch (_: Exception) {}
            passthroughView = null
        }
        cursorView?.let { v ->
            try { (window.decorView as? android.view.ViewGroup)?.removeView(v) } catch (_: Exception) {}
            cursorView = null
            cursorBroughtToFront = false
        }
        btClient?.stop()
        btClient = null
        super.onDestroy()
    }

    // Volume keys adjust the system STREAM_MUSIC volume (for correct gain staging
    // through the audio hardware) and also notify Flutter so the WebView JS
    // volume property stays in sync.
    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        // The Rokid touchpad firmware maps a DOUBLE-TAP to KEYCODE_BACK. Left
        // alone, Android finishes the Activity (app exits). Intercept BACK coming
        // FROM the touchpad device and route it to browser-back instead, so a
        // double-tap navigates back in web history and never quits the app. We
        // scope this to the touchpad device name so a real system Back (if any)
        // from another source still behaves normally.
        val fromTouchpad = event.device?.name.orEmpty().contains("PSOC-TP", ignoreCase = true)
        if (event.keyCode == KeyEvent.KEYCODE_BACK && fromTouchpad) {
            if (event.action == KeyEvent.ACTION_DOWN && event.repeatCount == 0) {
                // Dedup the double KEYCODE_BACK burst one gesture produces.
                val now = System.currentTimeMillis()
                if (now - lastBackMs > 150) {
                    lastBackMs = now
                    val json = JSONObject()
                        .put("type", "browser_cmd")
                        .put("action", "touchpad_back")
                        .toString()
                    runOnUiThread { eventSink?.success(json) }
                }
            }
            return true // consume both down & up so the OS never sees BACK
        }
        if (event.action == KeyEvent.ACTION_DOWN) {
            val direction = when (event.keyCode) {
                KeyEvent.KEYCODE_VOLUME_UP   -> AudioManager.ADJUST_RAISE to "volume_up"
                KeyEvent.KEYCODE_VOLUME_DOWN -> AudioManager.ADJUST_LOWER to "volume_down"
                else -> null
            }
            if (direction != null) {
                val am = getSystemService(AUDIO_SERVICE) as AudioManager
                am.adjustStreamVolume(
                    AudioManager.STREAM_MUSIC,
                    direction.first,
                    AudioManager.FLAG_SHOW_UI
                )
                val json = JSONObject()
                    .put("type", "browser_cmd")
                    .put("action", direction.second)
                    .toString()
                runOnUiThread { eventSink?.success(json) }
                return true
            }
        }
        return super.dispatchKeyEvent(event)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            METHOD_CHANNEL
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "exitApp" -> {
                    result.success(true)
                    finishAffinity()
                }
                "setWebViewTransparent" -> {
                    val on = call.arguments as? Boolean ?: false
                    val wv = findWebView(window.decorView)
                    if (wv != null) {
                        wv.setBackgroundColor(if (on) 0x00000000 else 0xFF000000.toInt())
                    }
                    // The Flutter view + window also need a transparent backdrop.
                    try {
                        window.setBackgroundDrawable(android.graphics.drawable.ColorDrawable(if (on) 0x00000000 else 0xFF000000.toInt()))
                    } catch (_: Exception) {}
                    result.success(true)
                }
                "wifiEnable" -> {
                    ensureWifiOn()
                    result.success(true)
                }
                "wifiDisable" -> {
                    @Suppress("DEPRECATION")
                    wifiManager().setWifiEnabled(false)
                    mainHandler.postDelayed({ sendWifiState() }, 1000)
                    result.success(true)
                }
                "wifiStatus" -> {
                    result.success(buildWifiJson())
                }
                "wifiConnect" -> {
                    val args = call.arguments as? Map<*, *>
                    val ssid = args?.get("ssid") as? String ?: ""
                    val password = args?.get("password") as? String ?: ""
                    val ok = connectToWifi(ssid, password)
                    mainHandler.postDelayed({ sendWifiState() }, 5000)
                    result.success(ok)
                }
                "configureWebViewZoom" -> {
                    val wv = findWebView(window.decorView)
                    if (wv != null) {
                        wv.settings.useWideViewPort = true
                        wv.settings.loadWithOverviewMode = true
                        applyForceDark(wv, true)
                        // Remove the green edge-glow (overscroll) + scrollbars that
                        // draw a rectangle outline around the WebView using the theme
                        // accent color.
                        wv.overScrollMode = android.view.View.OVER_SCROLL_NEVER
                        wv.isVerticalScrollBarEnabled = false
                        wv.isHorizontalScrollBarEnabled = false
                        wv.scrollBarStyle = android.view.View.SCROLLBARS_INSIDE_OVERLAY
                        wv.setBackgroundColor(0xFF000000.toInt())
                        // Kill the default focus highlight rectangle (drawn with the
                        // theme accent = the green frame around the WebView).
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            wv.defaultFocusHighlightEnabled = false
                        }
                        wv.foreground = null
                        // Walk up parents and clear any foreground/focus highlight too.
                        var p = wv.parent
                        var hops = 0
                        while (p is android.view.View && hops < 6) {
                            try {
                                (p as android.view.View).foreground = null
                                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                                    (p as android.view.View).defaultFocusHighlightEnabled = false
                                }
                            } catch (_: Exception) {}
                            p = (p as android.view.View).parent
                            hops++
                        }
                    }
                    result.success(wv != null)
                }
                "setForceDark" -> {
                    val enable = call.arguments as? Boolean ?: true
                    val wv = findWebView(window.decorView)
                    if (wv != null) applyForceDark(wv, enable)
                    // Brightness is fully decoupled from dark mode. Do NOT touch
                    // screenBrightness here — it's owned solely by the "setDim"
                    // command/slider and persists as a window attribute across page
                    // navigations and theme changes. (Previously this reset the
                    // user's brightness to full on every page load in light mode.)
                    result.success(wv != null)
                }
                "setDim" -> {
                    val v = (call.arguments as? Number)?.toFloat() ?: 0f
                    userDimLevel = v.coerceIn(0f, 1f) // remember the user's choice
                    setScreenDim(userDimLevel)
                    result.success(true)
                }
                "captureFrame" -> {
                    val args = call.arguments as? Map<*, *>
                    val maxWidth = (args?.get("maxWidth") as? Number)?.toInt() ?: 480
                    val maxHeight = (args?.get("maxHeight") as? Number)?.toInt() ?: 640
                    pixelCopyCapture.capture(
                        maxWidth,
                        maxHeight,
                        onFrame = { byteArray -> result.success(byteArray) },
                        onError = { message ->
                            result.error("capture_failed", message, null)
                        }
                    )
                }
                "beep" -> {
                    // Google-voice-like cue: rising tone on start, falling on stop.
                    val kind = (call.arguments as? Map<*, *>)?.get("kind") as? String ?: "start"
                    Thread {
                        try {
                            val rate = 22050
                            val f1 = if (kind == "start") 660.0 else 880.0
                            val f2 = if (kind == "start") 880.0 else 660.0
                            val n = rate / 6
                            val pcm = ShortArray(n * 2)
                            for (i in 0 until n) { pcm[i] = (Math.sin(2 * Math.PI * f1 * i / rate) * 9000 * Math.min(1.0, i / 300.0)).toInt().toShort() }
                            for (i in 0 until n) { pcm[n + i] = (Math.sin(2 * Math.PI * f2 * i / rate) * 9000 * (1 - i.toDouble() / n)).toInt().toShort() }
                            val at = android.media.AudioTrack.Builder()
                                .setAudioAttributes(android.media.AudioAttributes.Builder().setUsage(android.media.AudioAttributes.USAGE_ASSISTANCE_SONIFICATION).setContentType(android.media.AudioAttributes.CONTENT_TYPE_SONIFICATION).build())
                                .setAudioFormat(android.media.AudioFormat.Builder().setEncoding(android.media.AudioFormat.ENCODING_PCM_16BIT).setSampleRate(rate).setChannelMask(android.media.AudioFormat.CHANNEL_OUT_MONO).build())
                                .setBufferSizeInBytes(pcm.size * 2).setTransferMode(android.media.AudioTrack.MODE_STATIC).build()
                            at.write(pcm, 0, pcm.size); at.play(); Thread.sleep(400); at.release()
                        } catch (_: Exception) {}
                    }.start()
                    result.success(true)
                }
                "ttsPlay" -> {
                    // Play a PCM16 clip (Gemini TTS) through a streaming AudioTrack.
                    val args = call.arguments as? Map<*, *>
                    val pcm = args?.get("pcm") as? ByteArray
                    val rate = (args?.get("rate") as? Int) ?: 24000
                    if (pcm == null) { result.success(false); return@setMethodCallHandler }
                    ttsTrack?.let { try { it.stop(); it.release() } catch (_: Exception) {} }
                    Thread {
                        try {
                            val at = android.media.AudioTrack.Builder()
                                .setAudioAttributes(android.media.AudioAttributes.Builder().setUsage(android.media.AudioAttributes.USAGE_MEDIA).setContentType(android.media.AudioAttributes.CONTENT_TYPE_SPEECH).build())
                                .setAudioFormat(android.media.AudioFormat.Builder().setEncoding(android.media.AudioFormat.ENCODING_PCM_16BIT).setSampleRate(rate).setChannelMask(android.media.AudioFormat.CHANNEL_OUT_MONO).build())
                                .setBufferSizeInBytes(maxOf(pcm.size, 8192)).setTransferMode(android.media.AudioTrack.MODE_STREAM).build()
                            ttsTrack = at
                            at.play()
                            var off = 0
                            while (off < pcm.size && ttsTrack === at) {
                                val n = at.write(pcm, off, minOf(4096, pcm.size - off))
                                if (n <= 0) break
                                off += n
                            }
                            if (ttsTrack === at) { at.stop(); at.release(); if (ttsTrack === at) ttsTrack = null }
                        } catch (_: Exception) {}
                    }.start()
                    result.success(true)
                }
                "ttsStop" -> {
                    ttsTrack?.let { try { it.pause(); it.flush(); it.release() } catch (_: Exception) {} }
                    ttsTrack = null
                    result.success(true)
                }
                "asrStart" -> {
                    if (asrThread != null) { result.success(true); return@setMethodCallHandler }
                    val f = java.io.File(cacheDir, "asr.wav"); asrFile = f
                    asrStop = false
                    val t = Thread {
                        val rate = 16000
                        val minBuf = android.media.AudioRecord.getMinBufferSize(rate, android.media.AudioFormat.CHANNEL_IN_MONO, android.media.AudioFormat.ENCODING_PCM_16BIT)
                        // RV101 audio HAL has no VOICE_RECOGNITION graph (read fails -19);
                        // VOICE_COMMUNICATION (what the WebView uses) and MIC work.
                        var rec: android.media.AudioRecord? = null
                        for (src in intArrayOf(android.media.MediaRecorder.AudioSource.VOICE_COMMUNICATION, android.media.MediaRecorder.AudioSource.MIC, android.media.MediaRecorder.AudioSource.DEFAULT)) {
                            try {
                                val cand = android.media.AudioRecord(src, rate, android.media.AudioFormat.CHANNEL_IN_MONO, android.media.AudioFormat.ENCODING_PCM_16BIT, maxOf(minBuf, 8192))
                                if (cand.state == android.media.AudioRecord.STATE_INITIALIZED) {
                                    cand.startRecording()
                                    val probe = ByteArray(1024)
                                    val n = cand.read(probe, 0, probe.size)
                                    if (n > 0) { rec = cand; break } else { cand.release() }
                                } else cand.release()
                            } catch (_: Exception) {}
                        }
                        val out = java.io.ByteArrayOutputStream()
                        if (rec != null) {
                            val buf = ByteArray(4096)
                            val deadline = System.currentTimeMillis() + 15000
                            while (!asrStop && System.currentTimeMillis() < deadline) {
                                val n = rec.read(buf, 0, buf.size); if (n > 0) out.write(buf, 0, n)
                            }
                            try { rec.stop() } catch (_: Exception) {}
                            rec.release()
                        }
                        val pcm = out.toByteArray()
                        var peak = 0
                        var i = 0
                        while (i + 1 < pcm.size) { val v = ((pcm[i + 1].toInt() shl 8) or (pcm[i].toInt() and 0xff)).toShort().toInt(); if (Math.abs(v) > peak) peak = Math.abs(v); i += 2 }
                        Log.i("RokidASR", "recorded bytes=" + pcm.size + " peak=" + peak + " source=" + (rec?.audioSource ?: -1))
                        java.io.FileOutputStream(f).use { fo ->
                            val h = java.nio.ByteBuffer.allocate(44).order(java.nio.ByteOrder.LITTLE_ENDIAN)
                            h.put("RIFF".toByteArray()).putInt(36 + pcm.size).put("WAVE".toByteArray()).put("fmt ".toByteArray())
                                .putInt(16).putShort(1).putShort(1).putInt(rate).putInt(rate * 2).putShort(2).putShort(16)
                                .put("data".toByteArray()).putInt(pcm.size)
                            fo.write(h.array()); fo.write(pcm)
                        }
                        asrThread = null
                    }
                    asrThread = t; t.start()
                    result.success(true)
                }
                "asrStop" -> {
                    asrStop = true
                    val t = asrThread
                    Thread {
                        try { t?.join(3000) } catch (_: Exception) {}
                        val f = asrFile
                        runOnUiThread { result.success(if (f != null && f.exists()) f.absolutePath else null) }
                    }.start()
                }
                "filesDir" -> {
                    result.success(filesDir.absolutePath)
                }
                "capturePhoto" -> {
                    // World-facing camera still capture -> JPEG bytes for Gemini.
                    if (androidx.core.content.ContextCompat.checkSelfPermission(this, android.Manifest.permission.CAMERA)
                        != android.content.pm.PackageManager.PERMISSION_GRANTED) {
                        requestPermissions(arrayOf(android.Manifest.permission.CAMERA), 202)
                        result.error("no_permission", "Camera permission not granted yet; try again", null)
                    } else {
                        val maxDim = (call.argument<Int>("maxDim")) ?: 1280
                        try {
                            CameraHelper(this).capturePhoto(maxDim) { bytes ->
                                runOnUiThread {
                                    if (bytes != null && bytes.isNotEmpty()) result.success(bytes)
                                    else result.error("capture_failed", "Camera capture failed", null)
                                }
                            }
                        } catch (e: Exception) {
                            result.error("capture_failed", e.message, null)
                        }
                    }
                }
                "cursorScreenPos" -> {
                    // Actual on-screen centre of the cursor dot in window logical px.
                    val cv = cursorView
                    val d = resources.displayMetrics.density
                    if (cv == null) { result.success(null) } else {
                        val loc = IntArray(2); cv.getLocationInWindow(loc)
                        result.success(listOf(((loc[0] + cv.width / 2f) / d).toDouble(), ((loc[1] + cv.height / 2f) / d).toDouble()))
                    }
                }
                "cursorOffsetY" -> {
                    // Logical-px Y offset the cursor overlay adds (WebView top in window).
                    val wv = findWebView(window.decorView)
                    val d = resources.displayMetrics.density
                    val off = if (wv != null) { val l = IntArray(2); wv.getLocationInWindow(l); l[1] / d } else 0f
                    result.success(off.toDouble())
                }
                "resetZoom" -> {
                    // A newly loaded page starts at 100%; keep our tracker in sync.
                    currentZoomFactor = 1f
                    result.success(true)
                }
                "setTextZoom" -> {
                    // Reader-style zoom: WebView native TEXT zoom (%). Bigger/smaller
                    // text that stays inside the mobile column width — no sideways
                    // scroll, no getting stuck at a min pinch-scale. 50%..200%.
                    val pct = (call.arguments as? Number)?.toInt() ?: 100
                    val wv = findWebView(window.decorView)
                    if (wv != null) {
                        wv.settings.textZoom = pct.coerceIn(50, 200)
                    }
                    result.success(wv != null)
                }
                "setThirdPartyCookies" -> {
                    val args = call.arguments as? Map<*, *>
                    val block = args?.get("block") as? Boolean ?: false
                    val cm = android.webkit.CookieManager.getInstance()
                    val wv = findWebView(window.decorView)
                    if (wv != null) {
                        cm.setAcceptThirdPartyCookies(wv, !block)
                        cm.flush()
                    }
                    result.success(wv != null)
                }
                "setPassthrough" -> {
                    // Add a black native View to the window's DecorView — this composites
                    // above everything including Chrome's hardware SurfaceView for fullscreen video.
                    // A Flutter widget overlay or WebView DOM div both fall below the video layer.
                    val active = call.arguments as? Boolean ?: false
                    if (active) {
                        if (passthroughView == null) {
                            val v = android.view.View(this)
                            v.setBackgroundColor(0xD9000000.toInt())
                            v.isClickable = false
                            v.isFocusable = false
                            v.alpha = 0f
                            (window.decorView as android.view.ViewGroup).addView(
                                v,
                                android.widget.FrameLayout.LayoutParams(
                                    android.view.ViewGroup.LayoutParams.MATCH_PARENT,
                                    android.view.ViewGroup.LayoutParams.MATCH_PARENT
                                )
                            )
                            passthroughView = v
                            v.animate().alpha(1f).setDuration(250).start()
                        }
                    } else {
                        passthroughView?.let { v ->
                            v.animate().alpha(0f).setDuration(250).withEndAction {
                                (window.decorView as? android.view.ViewGroup)?.removeView(v)
                                if (passthroughView === v) passthroughView = null
                            }.start()
                        }
                    }
                    result.success(true)
                }
                "clickAt" -> {
                    val args = call.arguments as? Map<*, *>
                    val lx = (args?.get("x") as? Number)?.toFloat() ?: 0f
                    val ly = (args?.get("y") as? Number)?.toFloat() ?: 0f
                    val isFullscreen = args?.get("fullscreen") as? Boolean ?: false
                    val density = resources.displayMetrics.density
                    val wv = findWebView(window.decorView)
                    if (wv != null) {
                        val t = android.os.SystemClock.uptimeMillis()
                        val wvLoc = IntArray(2)
                        wv.getLocationInWindow(wvLoc)
                        // Cursor coordinates are window/screen space; the WebView
                        // now starts below the HUD, so make them view-local.
                        val px = lx * density - wvLoc[0]
                        val py = ly * density - wvLoc[1]

                        // fullscreen flag is set by Flutter via JS (document.fullscreenElement
                        // or YouTube's aria-label check) — same logic as the double-tap exit.
                        val fsView = if (isFullscreen) findFullscreenView() else null

                        if (fsView != null) {
                            // Fullscreen path — dispatch ONLY to the fullscreen view.
                            // Do NOT also dispatch to wv; that would cause a double-click.
                            val fsLoc = IntArray(2)
                            fsView.getLocationInWindow(fsLoc)
                            val fsX = (wvLoc[0] + px) - fsLoc[0]
                            val fsY = (wvLoc[1] + py) - fsLoc[1]
                            val downFs = MotionEvent.obtain(t, t,       MotionEvent.ACTION_DOWN, fsX, fsY, 0)
                            val upFs   = MotionEvent.obtain(t, t + 80L, MotionEvent.ACTION_UP,   fsX, fsY, 0)
                            fsView.dispatchTouchEvent(downFs)
                            mainHandler.postDelayed({
                                fsView.dispatchTouchEvent(upFs)
                                downFs.recycle()
                                upFs.recycle()
                            }, 80)
                        } else {
                            // Normal path — dispatch ONLY to the WebView (trusted event,
                            // focuses <input> fields, passes isTrusted checks).
                            val down = MotionEvent.obtain(t, t,       MotionEvent.ACTION_DOWN, px, py, 0)
                            val up   = MotionEvent.obtain(t, t + 80L, MotionEvent.ACTION_UP,   px, py, 0)
                            wv.dispatchTouchEvent(down)
                            mainHandler.postDelayed({
                                wv.dispatchTouchEvent(up)
                                down.recycle()
                                up.recycle()
                                mainHandler.postDelayed({
                                    val imm = getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager
                                    imm.hideSoftInputFromWindow(wv.windowToken, 0)
                                }, 150)
                            }, 80)
                        }
                        result.success(true)
                    } else {
                        result.success(false)
                    }
                }
                "sendBrowserState" -> {
                    val args = call.arguments as? Map<*, *>
                    if (args != null) {
                        val json = JSONObject().apply {
                            put("type",         "browser_state")
                            put("url",          args["url"]          as? String  ?: "")
                            put("title",        args["title"]        as? String  ?: "")
                            put("loading",      args["loading"]      as? Boolean ?: false)
                            put("canGoBack",    args["canGoBack"]    as? Boolean ?: false)
                            put("canGoForward", args["canGoForward"] as? Boolean ?: false)
                            put("visualMode",   args["visualMode"]   as? String  ?: "normal")
                        }
                        btClient?.send(json.toString())
                    }
                    result.success(true)
                }
                "bookmarkCurrent" -> {
                    val args = call.arguments as? Map<*, *>
                    val url = args?.get("url") as? String ?: ""
                    val title = args?.get("title") as? String ?: ""
                    if (url.isNotEmpty()) {
                        val json = JSONObject()
                            .put("type", "bookmark_add")
                            .put("url", url)
                            .put("title", title.ifEmpty { url })
                            .toString()
                        btClient?.send(json)
                    }
                    result.success(true)
                }
                "updateCursor" -> {
                    val args = call.arguments as? Map<*, *>
                    val lx = (args?.get("x") as? Number)?.toFloat() ?: 0f
                    val ly = (args?.get("y") as? Number)?.toFloat() ?: 0f
                    val visible = args?.get("visible") as? Boolean ?: false
                    val dragging = args?.get("dragging") as? Boolean ?: false
                    val density = resources.displayMetrics.density
                    val sizePx = (14 * density).toInt()
                    val root = window.decorView as android.view.ViewGroup
                    if (cursorView == null) {
                        val cv = android.view.View(this)
                        cv.isClickable = false
                        cv.isFocusable = false
                        root.addView(cv, android.widget.FrameLayout.LayoutParams(sizePx, sizePx))
                        cursorView = cv
                    }
                    val cv = cursorView!!
                    // Cache the WebView offset; getLocationInWindow every frame is wasteful.
                    if (cursorWvOffsetY < 0f || cursorOffsetFrame % 30 == 0) {
                        val wv = findWebView(root)
                        cursorWvOffsetY = if (wv != null) {
                            val loc = IntArray(2)
                            wv.getLocationInWindow(loc)
                            loc[1].toFloat()
                        } else 0f
                    }
                    cursorOffsetFrame++
                    val wvOffsetY = cursorWvOffsetY

                    // Build the two drawables ONCE and reuse. Re-creating a GradientDrawable
                    // and reassigning background every frame forces a full redraw.
                    if (cursorDotNormal == null) {
                        cursorDotNormal = android.graphics.drawable.GradientDrawable().apply {
                            shape = android.graphics.drawable.GradientDrawable.OVAL
                            setColor(0xFFFFFFFF.toInt())
                            setStroke((1.5f * density).toInt(), 0x8A000000.toInt())
                        }
                        cursorDotDrag = android.graphics.drawable.GradientDrawable().apply {
                            shape = android.graphics.drawable.GradientDrawable.OVAL
                            setColor(0xFFFFA500.toInt())
                            setStroke((1.5f * density).toInt(), 0x8A000000.toInt())
                        }
                    }
                    val wantBg = if (dragging) cursorDotDrag else cursorDotNormal
                    if (cv.background !== wantBg) cv.background = wantBg

                    // Only move via translation (cheap, no relayout of siblings).
                    cv.x = lx * density - sizePx / 2f
                    cv.y = ly * density - sizePx / 2f
                    val wantVis = if (visible) android.view.View.VISIBLE else android.view.View.INVISIBLE
                    if (cv.visibility != wantVis) cv.visibility = wantVis
                    // bringToFront() relayouts the whole ViewGroup and triggers a full repaint
                    // (the WebView included) EVERY frame -> flashing + GPU heat. Do it only once
                    // when the cursor first appears, not on every move.
                    if (!cursorBroughtToFront) {
                        cv.bringToFront()
                        cursorBroughtToFront = true
                    }
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }

        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            EVENT_CHANNEL
        ).setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                eventSink = events

                if (btClient == null) {
                    btClient = BrowserBleServer(
                        context   = applicationContext,
                        onMessage = { json ->
                            runOnUiThread { eventSink?.success(json) }
                        },
                        onStatus  = { status ->
                            val statusJson = JSONObject()
                                .put("type", "bt_status")
                                .put("status", status)
                                .toString()
                            runOnUiThread { eventSink?.success(statusJson) }
                        }
                    )
                    btClient?.start()
                }

                // Report WiFi state immediately so phone UI is current on connect
                mainHandler.postDelayed({ sendWifiState() }, 800)
            }

            override fun onCancel(arguments: Any?) {
                eventSink = null
            }
        })
    }
}
