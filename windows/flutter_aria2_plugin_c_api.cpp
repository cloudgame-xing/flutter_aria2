#include "include/flutter_aria2/flutter_aria2_plugin_c_api.h"

#include <flutter/plugin_registrar_windows.h>

#include "flutter_aria2_plugin.h"

void FlutterAria2PluginCApiRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  flutter_aria2::FlutterAria2Plugin::RegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}
