#ifndef FLUTTER_PLUGIN_FLUTTER_ARIA2_PLUGIN_H_
#define FLUTTER_PLUGIN_FLUTTER_ARIA2_PLUGIN_H_

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>

#include <atomic>
#include <memory>
#include <thread>

#include <aria2_c_api.h>

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

 private:
  aria2_session_t* session_ = nullptr;
  bool library_initialized_ = false;

  // ── Background run loop (ARIA2_RUN_DEFAULT) ──
  std::thread run_thread_;
  std::atomic<bool> run_loop_active_{false};

  // Guards against concurrent one-shot aria2_run(ONCE) calls.
  std::atomic<bool> run_in_progress_{false};

  // Stop the background run loop (if active) and block until it exits.
  void StopRunLoop();

  // Block until a pending one-shot aria2_run finishes.
  void WaitForPendingRun();

  // Method channel for sending events back to Dart.
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;

  // Singleton instance pointer (used by the event callback).
  static FlutterAria2Plugin* instance_;

  // aria2 download event callback (C-compatible static function).
  static int DownloadEventCallback(aria2_session_t* session,
                                   aria2_download_event_t event,
                                   aria2_gid_t gid,
                                   void* user_data);
};

}  // namespace flutter_aria2

#endif  // FLUTTER_PLUGIN_FLUTTER_ARIA2_PLUGIN_H_
