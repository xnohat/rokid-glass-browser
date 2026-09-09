package com.rokid.rokid_browser_glasses

import android.content.Context
import android.graphics.ImageFormat
import android.hardware.camera2.CameraCaptureSession
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraDevice
import android.hardware.camera2.CameraManager
import android.hardware.camera2.CaptureRequest
import android.media.ImageReader
import android.os.Handler
import android.os.HandlerThread
import android.util.Log

/**
 * Minimal Camera2 still capture with no preview surface: opens the (front/world)
 * camera, grabs one JPEG via an ImageReader, then closes everything. Used by the
 * agent's see_camera / watch_camera tools. Requires CAMERA permission.
 */
class CameraHelper(private val context: Context) {

    private var thread: HandlerThread? = null
    private var handler: Handler? = null

    /** Capture a single JPEG. Calls [onDone] with bytes (or null on failure). */
    fun capturePhoto(maxDim: Int, onDone: (ByteArray?) -> Unit) {
        val mgr = context.getSystemService(Context.CAMERA_SERVICE) as CameraManager
        val cameraId = pickCamera(mgr) ?: run { onDone(null); return }
        val t = HandlerThread("cam").also { it.start() }
        thread = t
        val h = Handler(t.looper); handler = h

        val (w, h2) = pickSize(mgr, cameraId, maxDim)
        val reader = ImageReader.newInstance(w, h2, ImageFormat.JPEG, 1)
        var finished = false
        fun finish(bytes: ByteArray?) {
            if (finished) return
            finished = true
            try { reader.close() } catch (_: Exception) {}
            cleanup()
            onDone(bytes)
        }

        reader.setOnImageAvailableListener({ r ->
            try {
                val img = r.acquireLatestImage()
                if (img != null) {
                    val buf = img.planes[0].buffer
                    val bytes = ByteArray(buf.remaining()); buf.get(bytes)
                    img.close()
                    finish(bytes)
                } else finish(null)
            } catch (e: Exception) { Log.e("RokidCam", "read", e); finish(null) }
        }, h)

        try {
            mgr.openCamera(cameraId, object : CameraDevice.StateCallback() {
                override fun onOpened(device: CameraDevice) {
                    try {
                        val req = device.createCaptureRequest(CameraDevice.TEMPLATE_STILL_CAPTURE)
                        req.addTarget(reader.surface)
                        req.set(CaptureRequest.CONTROL_MODE, CaptureRequest.CONTROL_MODE_AUTO)
                        @Suppress("DEPRECATION")
                        device.createCaptureSession(listOf(reader.surface), object : CameraCaptureSession.StateCallback() {
                            override fun onConfigured(session: CameraCaptureSession) {
                                try {
                                    session.capture(req.build(), object : CameraCaptureSession.CaptureCallback() {
                                        override fun onCaptureFailed(s: CameraCaptureSession, rq: CaptureRequest, f: android.hardware.camera2.CaptureFailure) {
                                            device.close(); finish(null)
                                        }
                                    }, h)
                                    // Close the device shortly after the frame is delivered.
                                    h.postDelayed({ try { device.close() } catch (_: Exception) {} }, 1500)
                                } catch (e: Exception) { device.close(); finish(null) }
                            }
                            override fun onConfigureFailed(session: CameraCaptureSession) { device.close(); finish(null) }
                        }, h)
                    } catch (e: Exception) { device.close(); finish(null) }
                }
                override fun onDisconnected(device: CameraDevice) { device.close(); finish(null) }
                override fun onError(device: CameraDevice, error: Int) { device.close(); finish(null) }
            }, h)
        } catch (e: Exception) { Log.e("RokidCam", "open", e); finish(null) }

        // Safety timeout.
        h.postDelayed({ finish(null) }, 6000)
    }

    private fun pickCamera(mgr: CameraManager): String? {
        return try {
            val ids = mgr.cameraIdList
            // Prefer a back/world-facing camera, else the first available.
            ids.firstOrNull {
                mgr.getCameraCharacteristics(it)
                    .get(CameraCharacteristics.LENS_FACING) == CameraCharacteristics.LENS_FACING_BACK
            } ?: ids.firstOrNull()
        } catch (_: Exception) { null }
    }

    private fun pickSize(mgr: CameraManager, id: String, maxDim: Int): Pair<Int, Int> {
        return try {
            val map = mgr.getCameraCharacteristics(id)
                .get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)
            val sizes = map?.getOutputSizes(ImageFormat.JPEG)?.toList() ?: emptyList()
            // Largest size whose longest edge <= maxDim, else the smallest.
            val fit = sizes.filter { maxOf(it.width, it.height) <= maxDim }
                .maxByOrNull { it.width * it.height }
            val s = fit ?: sizes.minByOrNull { it.width * it.height }
            if (s != null) Pair(s.width, s.height) else Pair(640, 480)
        } catch (_: Exception) { Pair(640, 480) }
    }

    private fun cleanup() {
        try { thread?.quitSafely() } catch (_: Exception) {}
        thread = null; handler = null
    }
}
