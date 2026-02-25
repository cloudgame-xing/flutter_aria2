package me.junjie.xing.flutter_aria2

import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.MethodChannel

class Aria2NativeManager(
    private val channel: MethodChannel
) {
    @Suppress("unused") // Accessed from JNI.
    private var nativeHandle: Long = 0

    private val mainHandler = Handler(Looper.getMainLooper())

    init {
        if (nativeAvailable) {
            nativeInit()
            nativeSetEventSink(this)
        }
    }

    fun dispose() {
        if (nativeAvailable) {
            nativeSetEventSink(null)
            nativeDispose()
        }
    }

    fun invoke(method: String, arguments: Map<String, Any?>?): Any? {
        if (method == "getPlatformVersion") {
            return "Android ${Build.VERSION.RELEASE}"
        }
        if (!nativeAvailable) {
            throw Aria2NativeException(
                "NATIVE_MISSING",
                "Native library flutter_aria2_native is not available."
            )
        }
        return nativeInvoke(method, arguments)
    }

    @Suppress("unused") // Called from JNI.
    fun onDownloadEventFromNative(event: Int, gid: String) {
        val payload = mapOf(
            "event" to event,
            "gid" to gid
        )
        mainHandler.post {
            channel.invokeMethod("onDownloadEvent", payload)
        }
    }

    private external fun nativeInit()
    private external fun nativeDispose()
    private external fun nativeInvoke(method: String, arguments: Map<String, Any?>?): Any?

    private external fun nativeSetEventSink(manager: Aria2NativeManager?)

    companion object {
        private val nativeAvailable: Boolean = try {
            System.loadLibrary("flutter_aria2_native")
            true
        } catch (_: UnsatisfiedLinkError) {
            false
        }
    }
}
