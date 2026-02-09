#include "flutter_aria2_plugin.h"

#include <windows.h>
#include <VersionHelpers.h>

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>

#include <aria2_c_api.h>

#include <chrono>
#include <cstring>
#include <memory>
#include <sstream>
#include <string>
#include <thread>
#include <vector>

namespace flutter_aria2 {

// ──────────────────────── Type aliases ────────────────────────

using EV    = flutter::EncodableValue;
using EMap  = flutter::EncodableMap;
using EList = flutter::EncodableList;

// ──────────────────────── Helper utilities ────────────────────────

namespace {

// Get value from EncodableMap; returns nullptr when key absent or null.
const EV* MapGet(const EMap& m, const std::string& key) {
  auto it = m.find(EV(key));
  if (it == m.end()) return nullptr;
  if (std::holds_alternative<std::monostate>(it->second)) return nullptr;
  return &it->second;
}

std::string MapGetString(const EMap& m, const std::string& key,
                         const std::string& def = "") {
  if (auto* v = MapGet(m, key)) {
    if (auto* s = std::get_if<std::string>(v)) return *s;
  }
  return def;
}

int MapGetInt(const EMap& m, const std::string& key, int def = 0) {
  if (auto* v = MapGet(m, key)) {
    if (auto* i = std::get_if<int32_t>(v)) return *i;
    if (auto* i = std::get_if<int64_t>(v)) return static_cast<int>(*i);
  }
  return def;
}

bool MapGetBool(const EMap& m, const std::string& key, bool def = false) {
  if (auto* v = MapGet(m, key)) {
    if (auto* b = std::get_if<bool>(v)) return *b;
  }
  return def;
}

// ────── Key-value helper for aria2 options ──────

struct KeyValHelper {
  std::vector<std::string> keys;
  std::vector<std::string> values;
  std::vector<aria2_key_val_t> kvs;

  void fromMap(const EMap& map) {
    keys.reserve(map.size());
    values.reserve(map.size());
    for (const auto& pair : map) {
      keys.push_back(std::get<std::string>(pair.first));
      values.push_back(std::get<std::string>(pair.second));
    }
    kvs.resize(keys.size());
    for (size_t i = 0; i < keys.size(); ++i) {
      kvs[i].key   = const_cast<char*>(keys[i].c_str());
      kvs[i].value = const_cast<char*>(values[i].c_str());
    }
  }

  const aria2_key_val_t* data() const {
    return kvs.empty() ? nullptr : kvs.data();
  }
  size_t count() const { return kvs.size(); }
};

KeyValHelper OptionsFromMap(const EMap& args, const std::string& key) {
  KeyValHelper kv;
  if (auto* v = MapGet(args, key)) {
    if (auto* map = std::get_if<EMap>(v)) {
      kv.fromMap(*map);
    }
  }
  return kv;
}

// GID ↔ hex conversion wrapper (frees C-allocated memory).
std::string GidToHex(aria2_gid_t gid) {
  char* hex = aria2_gid_to_hex(gid);
  std::string result(hex ? hex : "");
  if (hex) aria2_free(hex);
  return result;
}

// Convert aria2_file_data_t → EncodableValue (map).
EV FileDataToEncodable(const aria2_file_data_t& f) {
  EMap m;
  m[EV("index")]           = EV(f.index);
  m[EV("path")]            = EV(std::string(f.path ? f.path : ""));
  m[EV("length")]          = EV(f.length);
  m[EV("completedLength")] = EV(f.completed_length);
  m[EV("selected")]        = EV(f.selected != 0);

  EList uris;
  for (size_t i = 0; i < f.uris_count; ++i) {
    EMap u;
    u[EV("uri")]    = EV(std::string(
        f.uris[i].uri ? f.uris[i].uri : ""));
    u[EV("status")] = EV(static_cast<int32_t>(f.uris[i].status));
    uris.push_back(u);
  }
  m[EV("uris")] = EV(uris);
  return EV(m);
}

}  // anonymous namespace

// ──────────────────────── Static members ────────────────────────

FlutterAria2Plugin* FlutterAria2Plugin::instance_ = nullptr;

// ──────────────────────── Registration ────────────────────────

void FlutterAria2Plugin::RegisterWithRegistrar(
    flutter::PluginRegistrarWindows *registrar) {
  auto plugin = std::make_unique<FlutterAria2Plugin>();

  plugin->channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          registrar->messenger(), "flutter_aria2",
          &flutter::StandardMethodCodec::GetInstance());

  plugin->channel_->SetMethodCallHandler(
      [plugin_pointer = plugin.get()](const auto &call, auto result) {
        plugin_pointer->HandleMethodCall(call, std::move(result));
      });

  instance_ = plugin.get();
  registrar->AddPlugin(std::move(plugin));
}

// ──────────────────────── Ctor / Dtor ────────────────────────

FlutterAria2Plugin::FlutterAria2Plugin() {}

FlutterAria2Plugin::~FlutterAria2Plugin() {
  StopRunLoop();
  WaitForPendingRun();

  if (session_) {
    aria2_session_final(session_);
    session_ = nullptr;
  }
  if (library_initialized_) {
    aria2_library_deinit();
    library_initialized_ = false;
  }
  if (instance_ == this) {
    instance_ = nullptr;
  }
}

void FlutterAria2Plugin::StopRunLoop() {
  if (!run_loop_active_.load()) return;

  run_loop_active_.store(false);

  // Signal aria2 to stop so aria2_run(DEFAULT) returns.
  if (session_) {
    aria2_shutdown(session_, /*force=*/1);
  }

  // Wait for the background thread to finish.
  if (run_thread_.joinable()) {
    run_thread_.join();
  }
}

void FlutterAria2Plugin::WaitForPendingRun() {
  while (run_in_progress_.load()) {
    std::this_thread::sleep_for(std::chrono::milliseconds(10));
  }
}

// ──────────────────────── Event callback ────────────────────────

int FlutterAria2Plugin::DownloadEventCallback(
    aria2_session_t* /*session*/,
    aria2_download_event_t event,
    aria2_gid_t gid,
    void* /*user_data*/) {
  if (instance_ && instance_->channel_) {
    EMap data;
    data[EV("event")] = EV(static_cast<int32_t>(event));
    data[EV("gid")]   = EV(GidToHex(gid));
    instance_->channel_->InvokeMethod(
        "onDownloadEvent",
        std::make_unique<EV>(data));
  }
  return 0;  // 0 = continue
}

// ──────────────────────── Method dispatch ────────────────────────

void FlutterAria2Plugin::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue> &method_call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {

  const auto& method = method_call.method_name();
  const auto* args   = method_call.arguments();

  // ────── getPlatformVersion ──────
  if (method == "getPlatformVersion") {
    std::ostringstream version_stream;
    version_stream << "Windows ";
    if (IsWindows10OrGreater()) {
      version_stream << "10+";
    } else if (IsWindows8OrGreater()) {
      version_stream << "8";
    } else if (IsWindows7OrGreater()) {
      version_stream << "7";
    }
    result->Success(EV(version_stream.str()));
    return;
  }

  // ════════════════════════════════════════════════════════════════
  //  Library init / deinit
  // ════════════════════════════════════════════════════════════════

  if (method == "libraryInit") {
    int ret = aria2_library_init();
    if (ret == 0) library_initialized_ = true;
    result->Success(EV(ret));
    return;
  }

  if (method == "libraryDeinit") {
    StopRunLoop();
    WaitForPendingRun();
    if (session_) {
      aria2_session_final(session_);
      session_ = nullptr;
    }
    int ret = aria2_library_deinit();
    library_initialized_ = false;
    result->Success(EV(ret));
    return;
  }

  // ════════════════════════════════════════════════════════════════
  //  Session management
  // ════════════════════════════════════════════════════════════════

  if (method == "sessionNew") {
    if (!library_initialized_) {
      result->Error("NOT_INITIALIZED",
                    "Call libraryInit() before sessionNew()");
      return;
    }
    if (session_) {
      result->Error("SESSION_EXISTS",
                    "Session already exists. Call sessionFinal() first.");
      return;
    }

    const auto& a = std::get<EMap>(*args);
    auto options = OptionsFromMap(a, "options");
    bool keep_running = MapGetBool(a, "keepRunning", true);

    aria2_session_config_t config;
    aria2_session_config_init(&config);
    config.keep_running = keep_running ? 1 : 0;
    config.download_event_callback = &FlutterAria2Plugin::DownloadEventCallback;
    config.user_data = this;

    session_ = aria2_session_new(options.data(),
                                 options.count(), &config);
    if (!session_) {
      result->Error("SESSION_FAILED", "aria2_session_new returned null");
      return;
    }
    result->Success(flutter::EncodableValue());
    return;
  }

  if (method == "sessionFinal") {
    if (!session_) {
      result->Error("NO_SESSION", "No active session");
      return;
    }
    StopRunLoop();
    WaitForPendingRun();
    int ret = aria2_session_final(session_);
    session_ = nullptr;
    result->Success(EV(ret));
    return;
  }

  // ════════════════════════════════════════════════════════════════
  //  Run (ARIA2_RUN_ONCE on a background thread to avoid blocking UI)
  // ════════════════════════════════════════════════════════════════

  if (method == "run") {
    if (!session_) {
      result->Error("NO_SESSION", "No active session");
      return;
    }
    // If a previous run is still in progress, skip this call.
    if (run_in_progress_.load()) {
      result->Success(EV(1));  // 1 = still active
      return;
    }

    run_in_progress_.store(true);

    // Transfer result ownership to the background thread.
    // Flutter Windows engine allows calling MethodResult from any thread.
    auto* result_ptr = result.release();
    auto* session    = session_;

    std::thread([this, result_ptr, session]() {
      int ret = 0;
      try {
        ret = aria2_run(session, ARIA2_RUN_ONCE);
      } catch (...) {
        ret = -1;
      }
      run_in_progress_.store(false);
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
          res(result_ptr);
      res->Success(EV(ret));
    }).detach();
    return;
  }

  // ════════════════════════════════════════════════════════════════
  //  Continuous run loop (ARIA2_RUN_DEFAULT on background thread)
  // ════════════════════════════════════════════════════════════════

  if (method == "startRunLoop") {
    if (!session_) {
      result->Error("NO_SESSION", "No active session");
      return;
    }
    if (run_loop_active_.load()) {
      result->Success(EV());  // Already running
      return;
    }

    run_loop_active_.store(true);
    auto* session = session_;

    // Join any previous thread first.
    if (run_thread_.joinable()) {
      run_thread_.join();
    }

    run_thread_ = std::thread([this, session]() {
      // aria2_run(DEFAULT) blocks and continuously processes I/O
      // using efficient multiplexing (select/epoll). It returns when
      // aria2_shutdown is called or (if keep_running is false) when
      // all downloads complete.
      aria2_run(session, ARIA2_RUN_DEFAULT);
      run_loop_active_.store(false);
    });

    result->Success(EV());
    return;
  }

  if (method == "stopRunLoop") {
    StopRunLoop();
    result->Success(EV());
    return;
  }

  // ════════════════════════════════════════════════════════════════
  //  Shutdown
  // ════════════════════════════════════════════════════════════════

  if (method == "shutdown") {
    if (!session_) {
      result->Error("NO_SESSION", "No active session");
      return;
    }
    const auto& a = std::get<EMap>(*args);
    int force = MapGetBool(a, "force", false) ? 1 : 0;
    int ret = aria2_shutdown(session_, force);
    result->Success(EV(ret));
    return;
  }

  // ════════════════════════════════════════════════════════════════
  //  Add URI
  // ════════════════════════════════════════════════════════════════

  if (method == "addUri") {
    if (!session_) {
      result->Error("NO_SESSION", "No active session");
      return;
    }
    const auto& a = std::get<EMap>(*args);

    // Parse URI list
    auto* uris_ev = MapGet(a, "uris");
    if (!uris_ev) {
      result->Error("BAD_ARGS", "Missing 'uris'");
      return;
    }
    const auto& uris_list = std::get<EList>(*uris_ev);
    std::vector<std::string> uri_strs;
    std::vector<const char*> uri_ptrs;
    uri_strs.reserve(uris_list.size());
    for (const auto& u : uris_list) {
      uri_strs.push_back(std::get<std::string>(u));
    }
    uri_ptrs.reserve(uri_strs.size());
    for (const auto& s : uri_strs) {
      uri_ptrs.push_back(s.c_str());
    }

    auto options  = OptionsFromMap(a, "options");
    int  position = MapGetInt(a, "position", -1);

    aria2_gid_t gid;
    int ret = aria2_add_uri(session_, &gid,
                            uri_ptrs.data(), uri_ptrs.size(),
                            options.data(), options.count(),
                            position);
    if (ret == 0) {
      result->Success(EV(GidToHex(gid)));
    } else {
      result->Error("ARIA2_ERROR",
                    "aria2_add_uri failed with code " + std::to_string(ret));
    }
    return;
  }

  // ════════════════════════════════════════════════════════════════
  //  Add Torrent
  // ════════════════════════════════════════════════════════════════

  if (method == "addTorrent") {
    if (!session_) {
      result->Error("NO_SESSION", "No active session");
      return;
    }
    const auto& a = std::get<EMap>(*args);
    std::string torrent_file = MapGetString(a, "torrentFile");

    // Webseed URIs (optional)
    std::vector<std::string> ws_strs;
    std::vector<const char*> ws_ptrs;
    if (auto* ws_ev = MapGet(a, "webseedUris")) {
      const auto& ws_list = std::get<EList>(*ws_ev);
      ws_strs.reserve(ws_list.size());
      for (const auto& u : ws_list) {
        ws_strs.push_back(std::get<std::string>(u));
      }
      ws_ptrs.reserve(ws_strs.size());
      for (const auto& s : ws_strs) {
        ws_ptrs.push_back(s.c_str());
      }
    }

    auto options  = OptionsFromMap(a, "options");
    int  position = MapGetInt(a, "position", -1);

    aria2_gid_t gid;
    int ret;
    if (ws_ptrs.empty()) {
      ret = aria2_add_torrent_simple(session_, &gid,
                                     torrent_file.c_str(),
                                     options.data(), options.count(),
                                     position);
    } else {
      ret = aria2_add_torrent(session_, &gid,
                              torrent_file.c_str(),
                              ws_ptrs.data(), ws_ptrs.size(),
                              options.data(), options.count(),
                              position);
    }

    if (ret == 0) {
      result->Success(EV(GidToHex(gid)));
    } else {
      result->Error("ARIA2_ERROR",
                    "aria2_add_torrent failed with code " +
                        std::to_string(ret));
    }
    return;
  }

  // ════════════════════════════════════════════════════════════════
  //  Add Metalink
  // ════════════════════════════════════════════════════════════════

  if (method == "addMetalink") {
    if (!session_) {
      result->Error("NO_SESSION", "No active session");
      return;
    }
    const auto& a = std::get<EMap>(*args);
    std::string metalink_file = MapGetString(a, "metalinkFile");
    auto options  = OptionsFromMap(a, "options");
    int  position = MapGetInt(a, "position", -1);

    aria2_gid_t* gids = nullptr;
    size_t gids_count = 0;
    int ret = aria2_add_metalink(session_, &gids, &gids_count,
                                 metalink_file.c_str(),
                                 options.data(), options.count(),
                                 position);
    if (ret == 0) {
      EList gid_list;
      for (size_t i = 0; i < gids_count; ++i) {
        gid_list.push_back(EV(GidToHex(gids[i])));
      }
      if (gids) aria2_free(gids);
      result->Success(EV(gid_list));
    } else {
      if (gids) aria2_free(gids);
      result->Error("ARIA2_ERROR",
                    "aria2_add_metalink failed with code " +
                        std::to_string(ret));
    }
    return;
  }

  // ════════════════════════════════════════════════════════════════
  //  Get active downloads
  // ════════════════════════════════════════════════════════════════

  if (method == "getActiveDownload") {
    if (!session_) {
      result->Error("NO_SESSION", "No active session");
      return;
    }
    aria2_gid_t* gids = nullptr;
    size_t gids_count = 0;
    int ret = aria2_get_active_download(session_, &gids, &gids_count);
    if (ret == 0) {
      EList gid_list;
      for (size_t i = 0; i < gids_count; ++i) {
        gid_list.push_back(EV(GidToHex(gids[i])));
      }
      if (gids) aria2_free(gids);
      result->Success(EV(gid_list));
    } else {
      if (gids) aria2_free(gids);
      result->Error("ARIA2_ERROR",
                    "aria2_get_active_download failed with code " +
                        std::to_string(ret));
    }
    return;
  }

  // ════════════════════════════════════════════════════════════════
  //  Remove / Pause / Unpause download
  // ════════════════════════════════════════════════════════════════

  if (method == "removeDownload") {
    if (!session_) {
      result->Error("NO_SESSION", "No active session");
      return;
    }
    const auto& a = std::get<EMap>(*args);
    std::string hex = MapGetString(a, "gid");
    bool force = MapGetBool(a, "force", false);
    aria2_gid_t gid = aria2_hex_to_gid(hex.c_str());
    int ret = aria2_remove_download(session_, gid, force ? 1 : 0);
    result->Success(EV(ret));
    return;
  }

  if (method == "pauseDownload") {
    if (!session_) {
      result->Error("NO_SESSION", "No active session");
      return;
    }
    const auto& a = std::get<EMap>(*args);
    std::string hex = MapGetString(a, "gid");
    bool force = MapGetBool(a, "force", false);
    aria2_gid_t gid = aria2_hex_to_gid(hex.c_str());
    int ret = aria2_pause_download(session_, gid, force ? 1 : 0);
    result->Success(EV(ret));
    return;
  }

  if (method == "unpauseDownload") {
    if (!session_) {
      result->Error("NO_SESSION", "No active session");
      return;
    }
    const auto& a = std::get<EMap>(*args);
    std::string hex = MapGetString(a, "gid");
    aria2_gid_t gid = aria2_hex_to_gid(hex.c_str());
    int ret = aria2_unpause_download(session_, gid);
    result->Success(EV(ret));
    return;
  }

  // ════════════════════════════════════════════════════════════════
  //  Change position
  // ════════════════════════════════════════════════════════════════

  if (method == "changePosition") {
    if (!session_) {
      result->Error("NO_SESSION", "No active session");
      return;
    }
    const auto& a = std::get<EMap>(*args);
    std::string hex = MapGetString(a, "gid");
    int pos = MapGetInt(a, "pos", 0);
    int how = MapGetInt(a, "how", 0);
    aria2_gid_t gid = aria2_hex_to_gid(hex.c_str());
    int ret = aria2_change_position(session_, gid, pos,
                                    static_cast<aria2_offset_mode_t>(how));
    result->Success(EV(ret));
    return;
  }

  // ════════════════════════════════════════════════════════════════
  //  Per-download options
  // ════════════════════════════════════════════════════════════════

  if (method == "changeOption") {
    if (!session_) {
      result->Error("NO_SESSION", "No active session");
      return;
    }
    const auto& a = std::get<EMap>(*args);
    std::string hex = MapGetString(a, "gid");
    auto options = OptionsFromMap(a, "options");
    aria2_gid_t gid = aria2_hex_to_gid(hex.c_str());
    int ret = aria2_change_option(session_, gid,
                                  options.data(), options.count());
    result->Success(EV(ret));
    return;
  }

  // ════════════════════════════════════════════════════════════════
  //  Global options
  // ════════════════════════════════════════════════════════════════

  if (method == "getGlobalOption") {
    if (!session_) {
      result->Error("NO_SESSION", "No active session");
      return;
    }
    const auto& a = std::get<EMap>(*args);
    std::string name = MapGetString(a, "name");
    char* val = aria2_get_global_option(session_, name.c_str());
    if (val) {
      result->Success(EV(std::string(val)));
      aria2_free(val);
    } else {
      result->Success(EV());  // null
    }
    return;
  }

  if (method == "getGlobalOptions") {
    if (!session_) {
      result->Error("NO_SESSION", "No active session");
      return;
    }
    aria2_key_val_t* opts = nullptr;
    size_t opts_count = 0;
    int ret = aria2_get_global_options(session_, &opts, &opts_count);
    if (ret == 0) {
      EMap m;
      for (size_t i = 0; i < opts_count; ++i) {
        m[EV(std::string(opts[i].key ? opts[i].key : ""))] =
            EV(std::string(opts[i].value ? opts[i].value : ""));
      }
      if (opts) aria2_free_key_vals(opts, opts_count);
      result->Success(EV(m));
    } else {
      if (opts) aria2_free_key_vals(opts, opts_count);
      result->Error("ARIA2_ERROR",
                    "aria2_get_global_options failed with code " +
                        std::to_string(ret));
    }
    return;
  }

  if (method == "changeGlobalOption") {
    if (!session_) {
      result->Error("NO_SESSION", "No active session");
      return;
    }
    const auto& a = std::get<EMap>(*args);
    auto options = OptionsFromMap(a, "options");
    int ret = aria2_change_global_option(session_,
                                         options.data(), options.count());
    result->Success(EV(ret));
    return;
  }

  // ════════════════════════════════════════════════════════════════
  //  Global statistics
  // ════════════════════════════════════════════════════════════════

  if (method == "getGlobalStat") {
    if (!session_) {
      result->Error("NO_SESSION", "No active session");
      return;
    }
    aria2_global_stat_t stat = aria2_get_global_stat(session_);
    EMap m;
    m[EV("downloadSpeed")] = EV(stat.download_speed);
    m[EV("uploadSpeed")]   = EV(stat.upload_speed);
    m[EV("numActive")]     = EV(stat.num_active);
    m[EV("numWaiting")]    = EV(stat.num_waiting);
    m[EV("numStopped")]    = EV(stat.num_stopped);
    result->Success(EV(m));
    return;
  }

  // ════════════════════════════════════════════════════════════════
  //  Download info (aggregated from download handle)
  // ════════════════════════════════════════════════════════════════

  if (method == "getDownloadInfo") {
    if (!session_) {
      result->Error("NO_SESSION", "No active session");
      return;
    }
    const auto& a = std::get<EMap>(*args);
    std::string hex = MapGetString(a, "gid");
    aria2_gid_t gid = aria2_hex_to_gid(hex.c_str());

    aria2_download_handle_t* dh =
        aria2_get_download_handle(session_, gid);
    if (!dh) {
      result->Error("HANDLE_FAILED",
                    "aria2_get_download_handle returned null for gid " + hex);
      return;
    }

    EMap m;
    m[EV("gid")]             = EV(hex);
    m[EV("status")]          = EV(static_cast<int32_t>(
                                   aria2_download_handle_get_status(dh)));
    m[EV("totalLength")]     = EV(aria2_download_handle_get_total_length(dh));
    m[EV("completedLength")] = EV(aria2_download_handle_get_completed_length(dh));
    m[EV("uploadLength")]    = EV(aria2_download_handle_get_upload_length(dh));
    m[EV("downloadSpeed")]   = EV(aria2_download_handle_get_download_speed(dh));
    m[EV("uploadSpeed")]     = EV(aria2_download_handle_get_upload_speed(dh));

    // Info hash → hex string
    aria2_binary_t ih = aria2_download_handle_get_info_hash(dh);
    if (ih.data && ih.length > 0) {
      std::ostringstream ss;
      for (size_t i = 0; i < ih.length; ++i) {
        char buf[3];
        snprintf(buf, sizeof(buf), "%02x", ih.data[i]);
        ss << buf;
      }
      m[EV("infoHash")] = EV(ss.str());
      aria2_free_binary(&ih);
    } else {
      m[EV("infoHash")] = EV(std::string(""));
    }

    m[EV("pieceLength")]  = EV(static_cast<int64_t>(
                                 aria2_download_handle_get_piece_length(dh)));
    m[EV("numPieces")]    = EV(aria2_download_handle_get_num_pieces(dh));
    m[EV("connections")]  = EV(aria2_download_handle_get_connections(dh));
    m[EV("errorCode")]    = EV(aria2_download_handle_get_error_code(dh));

    // Followed by
    aria2_gid_t* fb_gids = nullptr;
    size_t fb_count = 0;
    EList followed_by;
    if (aria2_download_handle_get_followed_by(dh, &fb_gids, &fb_count) == 0) {
      for (size_t i = 0; i < fb_count; ++i) {
        followed_by.push_back(EV(GidToHex(fb_gids[i])));
      }
      if (fb_gids) aria2_free(fb_gids);
    }
    m[EV("followedBy")] = EV(followed_by);

    m[EV("following")] = EV(GidToHex(
        aria2_download_handle_get_following(dh)));
    m[EV("belongsTo")] = EV(GidToHex(
        aria2_download_handle_get_belongs_to(dh)));

    char* dir = aria2_download_handle_get_dir(dh);
    m[EV("dir")] = EV(std::string(dir ? dir : ""));
    if (dir) aria2_free(dir);

    m[EV("numFiles")] = EV(aria2_download_handle_get_num_files(dh));

    aria2_delete_download_handle(dh);
    result->Success(EV(m));
    return;
  }

  // ════════════════════════════════════════════════════════════════
  //  Download files
  // ════════════════════════════════════════════════════════════════

  if (method == "getDownloadFiles") {
    if (!session_) {
      result->Error("NO_SESSION", "No active session");
      return;
    }
    const auto& a = std::get<EMap>(*args);
    std::string hex = MapGetString(a, "gid");
    aria2_gid_t gid = aria2_hex_to_gid(hex.c_str());

    aria2_download_handle_t* dh =
        aria2_get_download_handle(session_, gid);
    if (!dh) {
      result->Error("HANDLE_FAILED",
                    "aria2_get_download_handle returned null for gid " + hex);
      return;
    }

    aria2_file_data_t* files = nullptr;
    size_t files_count = 0;
    int ret = aria2_download_handle_get_files(dh, &files, &files_count);
    EList file_list;
    if (ret == 0 && files) {
      for (size_t i = 0; i < files_count; ++i) {
        file_list.push_back(FileDataToEncodable(files[i]));
      }
      aria2_free_file_data_array(files, files_count);
    }

    aria2_delete_download_handle(dh);
    result->Success(EV(file_list));
    return;
  }

  // ════════════════════════════════════════════════════════════════
  //  Download option(s)
  // ════════════════════════════════════════════════════════════════

  if (method == "getDownloadOption") {
    if (!session_) {
      result->Error("NO_SESSION", "No active session");
      return;
    }
    const auto& a = std::get<EMap>(*args);
    std::string hex  = MapGetString(a, "gid");
    std::string name = MapGetString(a, "name");
    aria2_gid_t gid  = aria2_hex_to_gid(hex.c_str());

    aria2_download_handle_t* dh =
        aria2_get_download_handle(session_, gid);
    if (!dh) {
      result->Error("HANDLE_FAILED",
                    "aria2_get_download_handle returned null for gid " + hex);
      return;
    }

    char* val = aria2_download_handle_get_option(dh, name.c_str());
    if (val) {
      result->Success(EV(std::string(val)));
      aria2_free(val);
    } else {
      result->Success(EV());  // null
    }
    aria2_delete_download_handle(dh);
    return;
  }

  if (method == "getDownloadOptions") {
    if (!session_) {
      result->Error("NO_SESSION", "No active session");
      return;
    }
    const auto& a = std::get<EMap>(*args);
    std::string hex = MapGetString(a, "gid");
    aria2_gid_t gid = aria2_hex_to_gid(hex.c_str());

    aria2_download_handle_t* dh =
        aria2_get_download_handle(session_, gid);
    if (!dh) {
      result->Error("HANDLE_FAILED",
                    "aria2_get_download_handle returned null for gid " + hex);
      return;
    }

    aria2_key_val_t* opts = nullptr;
    size_t opts_count = 0;
    int ret = aria2_download_handle_get_options(dh, &opts, &opts_count);
    EMap m;
    if (ret == 0 && opts) {
      for (size_t i = 0; i < opts_count; ++i) {
        m[EV(std::string(opts[i].key ? opts[i].key : ""))] =
            EV(std::string(opts[i].value ? opts[i].value : ""));
      }
      aria2_free_key_vals(opts, opts_count);
    }

    aria2_delete_download_handle(dh);
    result->Success(EV(m));
    return;
  }

  // ════════════════════════════════════════════════════════════════
  //  Download BT meta info
  // ════════════════════════════════════════════════════════════════

  if (method == "getDownloadBtMetaInfo") {
    if (!session_) {
      result->Error("NO_SESSION", "No active session");
      return;
    }
    const auto& a = std::get<EMap>(*args);
    std::string hex = MapGetString(a, "gid");
    aria2_gid_t gid = aria2_hex_to_gid(hex.c_str());

    aria2_download_handle_t* dh =
        aria2_get_download_handle(session_, gid);
    if (!dh) {
      result->Error("HANDLE_FAILED",
                    "aria2_get_download_handle returned null for gid " + hex);
      return;
    }

    aria2_bt_meta_info_data_t meta =
        aria2_download_handle_get_bt_meta_info(dh);

    EMap m;
    // Announce list (list of list of strings)
    EList announce_list;
    for (size_t i = 0; i < meta.announce_list_count; ++i) {
      EList tier;
      for (size_t j = 0; j < meta.announce_list[i].count; ++j) {
        tier.push_back(EV(std::string(
            meta.announce_list[i].values[j]
                ? meta.announce_list[i].values[j]
                : "")));
      }
      announce_list.push_back(EV(tier));
    }
    m[EV("announceList")] = EV(announce_list);
    m[EV("comment")]      = EV(std::string(
        meta.comment ? meta.comment : ""));
    m[EV("creationDate")] = EV(meta.creation_date);
    m[EV("mode")]         = EV(static_cast<int32_t>(meta.mode));
    m[EV("name")]         = EV(std::string(
        meta.name ? meta.name : ""));

    aria2_free_bt_meta_info_data(&meta);
    aria2_delete_download_handle(dh);
    result->Success(EV(m));
    return;
  }

  // ════════════════════════════════════════════════════════════════
  //  Not implemented
  // ════════════════════════════════════════════════════════════════

  result->NotImplemented();
}

}  // namespace flutter_aria2
