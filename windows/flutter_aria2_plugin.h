#ifndef FLUTTER_PLUGIN_FLUTTER_ARIA2_PLUGIN_H_
#define FLUTTER_PLUGIN_FLUTTER_ARIA2_PLUGIN_H_

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>

#include <memory>

namespace flutter_aria2 {

class FlutterAria2Plugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows *registrar);

  FlutterAria2Plugin();

  virtual ~FlutterAria2Plugin();

  // Disallow copy and assign.
  FlutterAria2Plugin(const FlutterAria2Plugin&) = delete;
  FlutterAria2Plugin& operator=(const FlutterAria2Plugin&) = delete;

  // Called when a method is called on this plugin's channel from Dart.
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue> &method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
};

}  // namespace flutter_aria2

#endif  // FLUTTER_PLUGIN_FLUTTER_ARIA2_PLUGIN_H_
