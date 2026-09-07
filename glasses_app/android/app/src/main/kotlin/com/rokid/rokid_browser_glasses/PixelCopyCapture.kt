package com.rokid.rokid_browser_glasses

import android.graphics.Bitmap
import android.os.Handler
import android.view.PixelCopy
import android.view.Window
import android.view.SurfaceView
import android.view.View
import android.view.ViewGroup
import java.io.ByteArrayOutputStream
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
import kotlin.math.roundToInt

/** App-window-only JPEG capture. There is never more than one pending request. */
class PixelCopyCapture(private val window: Window, private val mainHandler: Handler) {
    private val encoder = Executors.newSingleThreadExecutor()
    private val current = AtomicReference<Request?>(null)
    @Volatile private var active = false

    private class Request(
        val success: (ByteArray) -> Unit,
        val error: (String) -> Unit
    ) {
        val completed = AtomicBoolean(false)
    }

    private fun findFlutterSurface(view: View): SurfaceView? {
        if (view is io.flutter.embedding.android.FlutterSurfaceView) return view
        if (view is ViewGroup) for (i in 0 until view.childCount) {
            findFlutterSurface(view.getChildAt(i))?.let { return it }
        }
        return null
    }

    fun start() { active = true }

    fun stop() {
        active = false
        current.getAndSet(null)?.let { finishError(it, "capture cancelled") }
    }

    fun shutdown() {
        stop()
        encoder.shutdownNow()
    }

    fun capture(
        maxWidth: Int,
        maxHeight: Int,
        onFrame: (ByteArray) -> Unit,
        onError: (String) -> Unit
    ) {
        val request = Request(onFrame, onError)
        if (!active) {
            finishError(request, "capture inactive")
            return
        }
        if (!current.compareAndSet(null, request)) {
            finishError(request, "capture already in flight")
            return
        }
        val source = findFlutterSurface(window.decorView)
        if (source == null || !source.holder.surface.isValid) {
            current.compareAndSet(request, null)
            finishError(request, "Flutter surface unavailable")
            return
        }
        val sourceWidth = source.width
        val sourceHeight = source.height
        if (sourceWidth <= 0 || sourceHeight <= 0) {
            current.compareAndSet(request, null)
            finishError(request, "window has no drawable size")
            return
        }
        val scale = minOf(
            maxWidth.coerceIn(160, 960).toFloat() / sourceWidth,
            maxHeight.coerceIn(160, 1280).toFloat() / sourceHeight,
            1f
        )
        val width = (sourceWidth * scale).roundToInt().coerceAtLeast(1)
        val height = (sourceHeight * scale).roundToInt().coerceAtLeast(1)
        val bitmap = try {
            Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        } catch (_: Throwable) {
            current.compareAndSet(request, null)
            finishError(request, "bitmap allocation failed")
            return
        }
        try {
            PixelCopy.request(
                source,
                bitmap,
                { result ->
                    if (result != PixelCopy.SUCCESS) {
                        bitmap.recycle()
                        completeError(request, "PixelCopy result $result")
                        return@request
                    }
                    try {
                        encoder.execute {
                            try {
                                if (!active || request.completed.get()) return@execute
                                val output = ByteArrayOutputStream()
                                if (!bitmap.compress(Bitmap.CompressFormat.JPEG, 68, output)) {
                                    completeError(request, "JPEG compression failed")
                                } else {
                                    completeSuccess(request, output.toByteArray())
                                }
                            } catch (_: Throwable) {
                                completeError(request, "JPEG compression failed")
                            } finally {
                                bitmap.recycle()
                            }
                        }
                    } catch (_: Throwable) {
                        bitmap.recycle()
                        completeError(request, "JPEG encoder unavailable")
                    }
                },
                mainHandler
            )
        } catch (_: Throwable) {
            bitmap.recycle()
            completeError(request, "PixelCopy request failed")
        }
    }

    private fun completeSuccess(request: Request, bytes: ByteArray) {
        current.compareAndSet(request, null)
        if (request.completed.compareAndSet(false, true)) {
            mainHandler.post { request.success(bytes) }
        }
    }

    private fun completeError(request: Request, message: String) {
        current.compareAndSet(request, null)
        finishError(request, message)
    }

    private fun finishError(request: Request, message: String) {
        if (request.completed.compareAndSet(false, true)) {
            mainHandler.post { request.error(message) }
        }
    }
}
