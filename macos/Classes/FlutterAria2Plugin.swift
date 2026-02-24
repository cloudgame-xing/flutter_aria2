import Cocoa
import FlutterMacOS

public class FlutterAria2Plugin: NSObject, FlutterPlugin {
  private let channel: FlutterMethodChannel
  private let native: FlutterAria2Native

  private init(channel: FlutterMethodChannel) {
    self.channel = channel
    self.native = FlutterAria2Native()
    super.init()

    native.onDownloadEvent = { [weak channel] event, gid in
      channel?.invokeMethod("onDownloadEvent", arguments: [
        "event": event,
        "gid": gid,
      ])
    }
  }

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "flutter_aria2", binaryMessenger: registrar.messenger)
    let instance = FlutterAria2Plugin(channel: channel)
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    native.invokeMethod(call.method, arguments: call.arguments as? [String: Any]) { value, error in
      guard let error else {
        result(value)
        return
      }

      let nsError = error as NSError
      let code = (nsError.userInfo["code"] as? String) ?? "NATIVE_ERROR"
      if code == "NOT_IMPLEMENTED" {
        result(FlutterMethodNotImplemented)
        return
      }
      result(FlutterError(code: code, message: nsError.localizedDescription, details: nil))
    }
  }
}
