package me.junjie.xing.flutter_aria2

import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result

/** FlutterAria2Plugin */
class FlutterAria2Plugin :
    FlutterPlugin,
    MethodCallHandler {
    private lateinit var channel: MethodChannel
    private lateinit var nativeManager: Aria2NativeManager

    override fun onAttachedToEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(flutterPluginBinding.binaryMessenger, "flutter_aria2")
        nativeManager = Aria2NativeManager(channel)
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(
        call: MethodCall,
        result: Result
    ) {
        try {
            val value = nativeManager.invoke(
                call.method,
                call.arguments as? Map<String, Any?>
            )
            result.success(value)
        } catch (e: Aria2NativeException) {
            result.error(e.code, e.message, null)
        } catch (e: IllegalArgumentException) {
            result.error("BAD_ARGS", e.message, null)
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        nativeManager.dispose()
    }
}
