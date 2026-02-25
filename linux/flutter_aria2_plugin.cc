#include "include/flutter_aria2/flutter_aria2_plugin.h"

#include <aria2_c_api.h>
#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>
#include <sys/utsname.h>

#include <atomic>
#include <cstdio>
#include <cstring>
#include <memory>
#include <sstream>
#include <string>
#include <thread>
#include <vector>

#include "../common/aria2_core.h"
#include "flutter_aria2_plugin_private.h"

#define FLUTTER_ARIA2_PLUGIN(obj) \
  (G_TYPE_CHECK_INSTANCE_CAST((obj), flutter_aria2_plugin_get_type(), \
                              FlutterAria2Plugin))

struct _FlutterAria2Plugin {
  GObject parent_instance;
  aria2_session_t* session = nullptr;
  gboolean library_initialized = FALSE;
  std::thread run_thread;
  std::atomic<bool> run_loop_active{false};
  std::atomic<bool> run_in_progress{false};
  FlMethodChannel* channel = nullptr;
};

G_DEFINE_TYPE(FlutterAria2Plugin, flutter_aria2_plugin, g_object_get_type())

namespace {

FlValue* map_get(FlValue* map, const gchar* key) {
  if (map == nullptr || fl_value_get_type(map) != FL_VALUE_TYPE_MAP) {
    return nullptr;
  }
  return fl_value_lookup_string(map, key);
}

std::string map_get_string(FlValue* map, const gchar* key,
                           const std::string& def = "") {
  FlValue* value = map_get(map, key);
  if (value != nullptr && fl_value_get_type(value) == FL_VALUE_TYPE_STRING) {
    return fl_value_get_string(value);
  }
  return def;
}

int map_get_int(FlValue* map, const gchar* key, int def = 0) {
  FlValue* value = map_get(map, key);
  if (value != nullptr && fl_value_get_type(value) == FL_VALUE_TYPE_INT) {
    return static_cast<int>(fl_value_get_int(value));
  }
  return def;
}

bool map_get_bool(FlValue* map, const gchar* key, bool def = false) {
  FlValue* value = map_get(map, key);
  if (value != nullptr && fl_value_get_type(value) == FL_VALUE_TYPE_BOOL) {
    return fl_value_get_bool(value);
  }
  return def;
}

struct KeyValHelper {
  std::vector<std::string> keys;
  std::vector<std::string> values;
  std::vector<aria2_key_val_t> kvs;

  void from_map(FlValue* map) {
    if (map == nullptr || fl_value_get_type(map) != FL_VALUE_TYPE_MAP) {
      return;
    }
    size_t count = fl_value_get_length(map);
    keys.reserve(count);
    values.reserve(count);
    for (size_t i = 0; i < count; ++i) {
      FlValue* k = fl_value_get_map_key(map, i);
      FlValue* v = fl_value_get_map_value(map, i);
      if (k == nullptr || v == nullptr ||
          fl_value_get_type(k) != FL_VALUE_TYPE_STRING ||
          fl_value_get_type(v) != FL_VALUE_TYPE_STRING) {
        continue;
      }
      keys.emplace_back(fl_value_get_string(k));
      values.emplace_back(fl_value_get_string(v));
    }
    kvs.resize(keys.size());
    for (size_t i = 0; i < keys.size(); ++i) {
      kvs[i].key = const_cast<char*>(keys[i].c_str());
      kvs[i].value = const_cast<char*>(values[i].c_str());
    }
  }

  const aria2_key_val_t* data() const { return kvs.empty() ? nullptr : kvs.data(); }
  size_t count() const { return kvs.size(); }
};

KeyValHelper options_from_map(FlValue* args, const gchar* key) {
  KeyValHelper kv;
  kv.from_map(map_get(args, key));
  return kv;
}

std::string gid_to_hex(aria2_gid_t gid) {
  char* hex = aria2_gid_to_hex(gid);
  std::string result = hex == nullptr ? "" : hex;
  if (hex != nullptr) {
    aria2_free(hex);
  }
  return result;
}

FlValue* file_data_to_fl_value(const aria2_file_data_t& file) {
  FlValue* map = fl_value_new_map();
  fl_value_set_string(map, "index", fl_value_new_int(file.index));
  fl_value_set_string(map, "path",
                      fl_value_new_string(file.path == nullptr ? "" : file.path));
  fl_value_set_string(map, "length", fl_value_new_int(file.length));
  fl_value_set_string(map, "completedLength",
                      fl_value_new_int(file.completed_length));
  fl_value_set_string(map, "selected", fl_value_new_bool(file.selected != 0));

  FlValue* uris = fl_value_new_list();
  for (size_t i = 0; i < file.uris_count; ++i) {
    FlValue* uri_map = fl_value_new_map();
    fl_value_set_string(
        uri_map, "uri",
        fl_value_new_string(file.uris[i].uri == nullptr ? "" : file.uris[i].uri));
    fl_value_set_string(uri_map, "status",
                        fl_value_new_int(static_cast<int64_t>(file.uris[i].status)));
    fl_value_append(uris, uri_map);
  }
  fl_value_set_string(map, "uris", uris);
  return map;
}

FlMethodResponse* success_response(FlValue* result) {
  return FL_METHOD_RESPONSE(fl_method_success_response_new(result));
}

FlMethodResponse* null_success_response() {
  return FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
}

FlMethodResponse* error_response(const gchar* code, const gchar* message) {
  return FL_METHOD_RESPONSE(fl_method_error_response_new(code, message, nullptr));
}

flutter_aria2::core::RuntimeState take_core_state(FlutterAria2Plugin* self) {
  flutter_aria2::core::RuntimeState core;
  core.session = self->session;
  core.library_initialized = self->library_initialized;
  core.run_thread = std::move(self->run_thread);
  core.run_loop_active.store(self->run_loop_active.load());
  core.run_in_progress.store(self->run_in_progress.load());
  return core;
}

void put_core_state(FlutterAria2Plugin* self,
                    flutter_aria2::core::RuntimeState&& core) {
  self->session = core.session;
  self->library_initialized = core.library_initialized;
  self->run_thread = std::move(core.run_thread);
  self->run_loop_active.store(core.run_loop_active.load());
  self->run_in_progress.store(core.run_in_progress.load());
}

void wait_for_pending_run(FlutterAria2Plugin* self) {
  auto core = take_core_state(self);
  flutter_aria2::core::WaitForPendingRun(&core);
  put_core_state(self, std::move(core));
}

void stop_run_loop(FlutterAria2Plugin* self) {
  auto core = take_core_state(self);
  flutter_aria2::core::StopRunLoop(&core);
  put_core_state(self, std::move(core));
}

struct EventPayload {
  FlutterAria2Plugin* plugin;
  int event;
  std::string gid;
};

gboolean send_download_event_on_main(gpointer user_data) {
  std::unique_ptr<EventPayload> payload(static_cast<EventPayload*>(user_data));
  if (payload->plugin == nullptr || payload->plugin->channel == nullptr) {
    return G_SOURCE_REMOVE;
  }
  g_autoptr(FlValue) args = fl_value_new_map();
  fl_value_set_string(args, "event", fl_value_new_int(payload->event));
  fl_value_set_string(args, "gid", fl_value_new_string(payload->gid.c_str()));
  fl_method_channel_invoke_method(payload->plugin->channel, "onDownloadEvent",
                                  args, nullptr, nullptr, nullptr);
  return G_SOURCE_REMOVE;
}

int download_event_callback(aria2_session_t* /*session*/,
                            aria2_download_event_t event, aria2_gid_t gid,
                            void* user_data) {
  auto* plugin = static_cast<FlutterAria2Plugin*>(user_data);
  auto* payload = new EventPayload{
      plugin,
      static_cast<int>(event),
      gid_to_hex(gid),
  };
  g_main_context_invoke(nullptr, send_download_event_on_main, payload);
  return 0;
}

}  // namespace

// Called when a method call is received from Flutter.
static void flutter_aria2_plugin_handle_method_call(
    FlutterAria2Plugin* self,
    FlMethodCall* method_call) {
  g_autoptr(FlMethodResponse) response = nullptr;

  const gchar* method = fl_method_call_get_name(method_call);
  FlValue* args = fl_method_call_get_args(method_call);

  if (strcmp(method, "getPlatformVersion") == 0) {
    response = get_platform_version();
  } else if (strcmp(method, "libraryInit") == 0) {
    auto core = take_core_state(self);
    int ret = flutter_aria2::core::LibraryInit(&core);
    put_core_state(self, std::move(core));
    response = success_response(fl_value_new_int(ret));
  } else if (strcmp(method, "libraryDeinit") == 0) {
    auto core = take_core_state(self);
    int ret = flutter_aria2::core::LibraryDeinit(&core);
    put_core_state(self, std::move(core));
    response = success_response(fl_value_new_int(ret));
  } else if (strcmp(method, "sessionNew") == 0) {
    if (!self->library_initialized) {
      response = error_response("NOT_INITIALIZED",
                                "Call libraryInit() before sessionNew()");
    } else if (self->session != nullptr) {
      response = error_response("SESSION_EXISTS",
                                "Session already exists. Call sessionFinal() first.");
    } else {
      KeyValHelper options = options_from_map(args, "options");
      bool keep_running = map_get_bool(args, "keepRunning", true);
      auto core = take_core_state(self);
      const char* error = flutter_aria2::core::SessionNew(
          &core, options.data(), options.count(), keep_running,
          &download_event_callback, self);
      put_core_state(self, std::move(core));
      if (error != nullptr) {
        response =
            error_response("SESSION_FAILED", "aria2_session_new returned null");
      } else {
        response = null_success_response();
      }
    }
  } else if (strcmp(method, "sessionFinal") == 0) {
    if (self->session == nullptr) {
      response = error_response("NO_SESSION", "No active session");
    } else {
      auto core = take_core_state(self);
      int ret = 0;
      flutter_aria2::core::SessionFinal(&core, &ret);
      put_core_state(self, std::move(core));
      response = success_response(fl_value_new_int(ret));
    }
  } else if (strcmp(method, "run") == 0) {
    if (self->session == nullptr) {
      response = error_response("NO_SESSION", "No active session");
    } else {
      auto core = take_core_state(self);
      int ret = flutter_aria2::core::RunOnce(&core);
      put_core_state(self, std::move(core));
      response = success_response(fl_value_new_int(ret));
    }
  } else if (strcmp(method, "startRunLoop") == 0) {
    if (self->session == nullptr) {
      response = error_response("NO_SESSION", "No active session");
    } else if (self->run_loop_active.load()) {
      response = null_success_response();
    } else {
      auto core = take_core_state(self);
      flutter_aria2::core::StartRunLoop(&core);
      put_core_state(self, std::move(core));
      response = null_success_response();
    }
  } else if (strcmp(method, "stopRunLoop") == 0) {
    stop_run_loop(self);
    response = null_success_response();
  } else if (strcmp(method, "shutdown") == 0) {
    if (self->session == nullptr) {
      response = error_response("NO_SESSION", "No active session");
    } else {
      int force = map_get_bool(args, "force", false) ? 1 : 0;
      auto core = take_core_state(self);
      int ret = 0;
      flutter_aria2::core::Shutdown(&core, force != 0, &ret);
      put_core_state(self, std::move(core));
      response = success_response(fl_value_new_int(ret));
    }
  } else if (strcmp(method, "addUri") == 0) {
    if (self->session == nullptr) {
      response = error_response("NO_SESSION", "No active session");
    } else {
      FlValue* uris = map_get(args, "uris");
      if (uris == nullptr || fl_value_get_type(uris) != FL_VALUE_TYPE_LIST) {
        response = error_response("BAD_ARGS", "Missing 'uris'");
      } else {
        std::vector<std::string> uri_strings;
        std::vector<const char*> uri_ptrs;
        size_t uri_count = fl_value_get_length(uris);
        uri_strings.reserve(uri_count);
        uri_ptrs.reserve(uri_count);
        for (size_t i = 0; i < uri_count; ++i) {
          FlValue* value = fl_value_get_list_value(uris, i);
          if (value != nullptr && fl_value_get_type(value) == FL_VALUE_TYPE_STRING) {
            uri_strings.emplace_back(fl_value_get_string(value));
          }
        }
        for (const std::string& uri : uri_strings) {
          uri_ptrs.push_back(uri.c_str());
        }

        KeyValHelper options = options_from_map(args, "options");
        int position = map_get_int(args, "position", -1);
        aria2_gid_t gid;
        int ret = aria2_add_uri(self->session, &gid, uri_ptrs.data(),
                                uri_ptrs.size(), options.data(), options.count(),
                                position);
        if (ret == 0) {
          response = success_response(fl_value_new_string(gid_to_hex(gid).c_str()));
        } else {
          g_autofree gchar* message =
              g_strdup_printf("aria2_add_uri failed with code %d", ret);
          response = error_response("ARIA2_ERROR", message);
        }
      }
    }
  } else if (strcmp(method, "addTorrent") == 0) {
    if (self->session == nullptr) {
      response = error_response("NO_SESSION", "No active session");
    } else {
      std::string torrent_file = map_get_string(args, "torrentFile");
      FlValue* ws = map_get(args, "webseedUris");
      std::vector<std::string> ws_strings;
      std::vector<const char*> ws_ptrs;
      if (ws != nullptr && fl_value_get_type(ws) == FL_VALUE_TYPE_LIST) {
        size_t ws_count = fl_value_get_length(ws);
        ws_strings.reserve(ws_count);
        ws_ptrs.reserve(ws_count);
        for (size_t i = 0; i < ws_count; ++i) {
          FlValue* value = fl_value_get_list_value(ws, i);
          if (value != nullptr && fl_value_get_type(value) == FL_VALUE_TYPE_STRING) {
            ws_strings.emplace_back(fl_value_get_string(value));
          }
        }
        for (const std::string& item : ws_strings) {
          ws_ptrs.push_back(item.c_str());
        }
      }

      KeyValHelper options = options_from_map(args, "options");
      int position = map_get_int(args, "position", -1);
      aria2_gid_t gid;
      int ret = ws_ptrs.empty()
                    ? aria2_add_torrent_simple(self->session, &gid,
                                               torrent_file.c_str(), options.data(),
                                               options.count(), position)
                    : aria2_add_torrent(self->session, &gid, torrent_file.c_str(),
                                        ws_ptrs.data(), ws_ptrs.size(),
                                        options.data(), options.count(), position);
      if (ret == 0) {
        response = success_response(fl_value_new_string(gid_to_hex(gid).c_str()));
      } else {
        g_autofree gchar* message =
            g_strdup_printf("aria2_add_torrent failed with code %d", ret);
        response = error_response("ARIA2_ERROR", message);
      }
    }
  } else if (strcmp(method, "addMetalink") == 0) {
    if (self->session == nullptr) {
      response = error_response("NO_SESSION", "No active session");
    } else {
      std::string metalink_file = map_get_string(args, "metalinkFile");
      KeyValHelper options = options_from_map(args, "options");
      int position = map_get_int(args, "position", -1);
      aria2_gid_t* gids = nullptr;
      size_t gids_count = 0;
      int ret =
          aria2_add_metalink(self->session, &gids, &gids_count, metalink_file.c_str(),
                             options.data(), options.count(), position);
      if (ret == 0) {
        FlValue* gid_list = fl_value_new_list();
        for (size_t i = 0; i < gids_count; ++i) {
          fl_value_append(gid_list, fl_value_new_string(gid_to_hex(gids[i]).c_str()));
        }
        if (gids != nullptr) {
          aria2_free(gids);
        }
        response = success_response(gid_list);
      } else {
        if (gids != nullptr) {
          aria2_free(gids);
        }
        g_autofree gchar* message =
            g_strdup_printf("aria2_add_metalink failed with code %d", ret);
        response = error_response("ARIA2_ERROR", message);
      }
    }
  } else if (strcmp(method, "getActiveDownload") == 0) {
    if (self->session == nullptr) {
      response = error_response("NO_SESSION", "No active session");
    } else {
      aria2_gid_t* gids = nullptr;
      size_t gids_count = 0;
      int ret = aria2_get_active_download(self->session, &gids, &gids_count);
      if (ret == 0) {
        FlValue* gid_list = fl_value_new_list();
        for (size_t i = 0; i < gids_count; ++i) {
          fl_value_append(gid_list, fl_value_new_string(gid_to_hex(gids[i]).c_str()));
        }
        if (gids != nullptr) {
          aria2_free(gids);
        }
        response = success_response(gid_list);
      } else {
        if (gids != nullptr) {
          aria2_free(gids);
        }
        g_autofree gchar* message =
            g_strdup_printf("aria2_get_active_download failed with code %d", ret);
        response = error_response("ARIA2_ERROR", message);
      }
    }
  } else if (strcmp(method, "removeDownload") == 0) {
    if (self->session == nullptr) {
      response = error_response("NO_SESSION", "No active session");
    } else {
      std::string gid_hex = map_get_string(args, "gid");
      bool force = map_get_bool(args, "force", false);
      aria2_gid_t gid = aria2_hex_to_gid(gid_hex.c_str());
      int ret = aria2_remove_download(self->session, gid, force ? 1 : 0);
      response = success_response(fl_value_new_int(ret));
    }
  } else if (strcmp(method, "pauseDownload") == 0) {
    if (self->session == nullptr) {
      response = error_response("NO_SESSION", "No active session");
    } else {
      std::string gid_hex = map_get_string(args, "gid");
      bool force = map_get_bool(args, "force", false);
      aria2_gid_t gid = aria2_hex_to_gid(gid_hex.c_str());
      int ret = aria2_pause_download(self->session, gid, force ? 1 : 0);
      response = success_response(fl_value_new_int(ret));
    }
  } else if (strcmp(method, "unpauseDownload") == 0) {
    if (self->session == nullptr) {
      response = error_response("NO_SESSION", "No active session");
    } else {
      std::string gid_hex = map_get_string(args, "gid");
      aria2_gid_t gid = aria2_hex_to_gid(gid_hex.c_str());
      int ret = aria2_unpause_download(self->session, gid);
      response = success_response(fl_value_new_int(ret));
    }
  } else if (strcmp(method, "changePosition") == 0) {
    if (self->session == nullptr) {
      response = error_response("NO_SESSION", "No active session");
    } else {
      std::string gid_hex = map_get_string(args, "gid");
      int pos = map_get_int(args, "pos", 0);
      int how = map_get_int(args, "how", 0);
      aria2_gid_t gid = aria2_hex_to_gid(gid_hex.c_str());
      int ret = aria2_change_position(self->session, gid, pos,
                                      static_cast<aria2_offset_mode_t>(how));
      response = success_response(fl_value_new_int(ret));
    }
  } else if (strcmp(method, "changeOption") == 0) {
    if (self->session == nullptr) {
      response = error_response("NO_SESSION", "No active session");
    } else {
      std::string gid_hex = map_get_string(args, "gid");
      KeyValHelper options = options_from_map(args, "options");
      aria2_gid_t gid = aria2_hex_to_gid(gid_hex.c_str());
      int ret = aria2_change_option(self->session, gid, options.data(),
                                    options.count());
      response = success_response(fl_value_new_int(ret));
    }
  } else if (strcmp(method, "getGlobalOption") == 0) {
    if (self->session == nullptr) {
      response = error_response("NO_SESSION", "No active session");
    } else {
      std::string name = map_get_string(args, "name");
      char* value = aria2_get_global_option(self->session, name.c_str());
      if (value != nullptr) {
        response = success_response(fl_value_new_string(value));
        aria2_free(value);
      } else {
        response = null_success_response();
      }
    }
  } else if (strcmp(method, "getGlobalOptions") == 0) {
    if (self->session == nullptr) {
      response = error_response("NO_SESSION", "No active session");
    } else {
      aria2_key_val_t* options = nullptr;
      size_t options_count = 0;
      int ret = aria2_get_global_options(self->session, &options, &options_count);
      if (ret == 0) {
        FlValue* map = fl_value_new_map();
        for (size_t i = 0; i < options_count; ++i) {
          fl_value_set_string(
              map, options[i].key == nullptr ? "" : options[i].key,
              fl_value_new_string(options[i].value == nullptr ? "" : options[i].value));
        }
        if (options != nullptr) {
          aria2_free_key_vals(options, options_count);
        }
        response = success_response(map);
      } else {
        if (options != nullptr) {
          aria2_free_key_vals(options, options_count);
        }
        g_autofree gchar* message =
            g_strdup_printf("aria2_get_global_options failed with code %d", ret);
        response = error_response("ARIA2_ERROR", message);
      }
    }
  } else if (strcmp(method, "changeGlobalOption") == 0) {
    if (self->session == nullptr) {
      response = error_response("NO_SESSION", "No active session");
    } else {
      KeyValHelper options = options_from_map(args, "options");
      int ret = aria2_change_global_option(self->session, options.data(),
                                           options.count());
      response = success_response(fl_value_new_int(ret));
    }
  } else if (strcmp(method, "getGlobalStat") == 0) {
    if (self->session == nullptr) {
      response = error_response("NO_SESSION", "No active session");
    } else {
      aria2_global_stat_t stat = aria2_get_global_stat(self->session);
      FlValue* map = fl_value_new_map();
      fl_value_set_string(map, "downloadSpeed",
                          fl_value_new_int(stat.download_speed));
      fl_value_set_string(map, "uploadSpeed", fl_value_new_int(stat.upload_speed));
      fl_value_set_string(map, "numActive", fl_value_new_int(stat.num_active));
      fl_value_set_string(map, "numWaiting", fl_value_new_int(stat.num_waiting));
      fl_value_set_string(map, "numStopped", fl_value_new_int(stat.num_stopped));
      response = success_response(map);
    }
  } else if (strcmp(method, "getDownloadInfo") == 0) {
    if (self->session == nullptr) {
      response = error_response("NO_SESSION", "No active session");
    } else {
      std::string gid_hex = map_get_string(args, "gid");
      aria2_gid_t gid = aria2_hex_to_gid(gid_hex.c_str());
      aria2_download_handle_t* handle = aria2_get_download_handle(self->session, gid);
      if (handle == nullptr) {
        g_autofree gchar* message = g_strdup_printf(
            "aria2_get_download_handle returned null for gid %s", gid_hex.c_str());
        response = error_response("HANDLE_FAILED", message);
      } else {
        FlValue* map = fl_value_new_map();
        fl_value_set_string(map, "gid", fl_value_new_string(gid_hex.c_str()));
        fl_value_set_string(
            map, "status",
            fl_value_new_int(static_cast<int>(aria2_download_handle_get_status(handle))));
        fl_value_set_string(
            map, "totalLength",
            fl_value_new_int(aria2_download_handle_get_total_length(handle)));
        fl_value_set_string(
            map, "completedLength",
            fl_value_new_int(aria2_download_handle_get_completed_length(handle)));
        fl_value_set_string(
            map, "uploadLength",
            fl_value_new_int(aria2_download_handle_get_upload_length(handle)));
        fl_value_set_string(
            map, "downloadSpeed",
            fl_value_new_int(aria2_download_handle_get_download_speed(handle)));
        fl_value_set_string(
            map, "uploadSpeed",
            fl_value_new_int(aria2_download_handle_get_upload_speed(handle)));

        aria2_binary_t info_hash = aria2_download_handle_get_info_hash(handle);
        if (info_hash.data != nullptr && info_hash.length > 0) {
          std::ostringstream stream;
          for (size_t i = 0; i < info_hash.length; ++i) {
            char buffer[3];
            snprintf(buffer, sizeof(buffer), "%02x", info_hash.data[i]);
            stream << buffer;
          }
          fl_value_set_string(map, "infoHash",
                              fl_value_new_string(stream.str().c_str()));
          aria2_free_binary(&info_hash);
        } else {
          fl_value_set_string(map, "infoHash", fl_value_new_string(""));
        }

        fl_value_set_string(
            map, "pieceLength",
            fl_value_new_int(aria2_download_handle_get_piece_length(handle)));
        fl_value_set_string(
            map, "numPieces",
            fl_value_new_int(aria2_download_handle_get_num_pieces(handle)));
        fl_value_set_string(
            map, "connections",
            fl_value_new_int(aria2_download_handle_get_connections(handle)));
        fl_value_set_string(
            map, "errorCode",
            fl_value_new_int(aria2_download_handle_get_error_code(handle)));

        aria2_gid_t* followed_by = nullptr;
        size_t followed_count = 0;
        FlValue* followed_list = fl_value_new_list();
        if (aria2_download_handle_get_followed_by(handle, &followed_by,
                                                  &followed_count) == 0) {
          for (size_t i = 0; i < followed_count; ++i) {
            fl_value_append(
                followed_list,
                fl_value_new_string(gid_to_hex(followed_by[i]).c_str()));
          }
          if (followed_by != nullptr) {
            aria2_free(followed_by);
          }
        }
        fl_value_set_string(map, "followedBy", followed_list);
        fl_value_set_string(
            map, "following",
            fl_value_new_string(
                gid_to_hex(aria2_download_handle_get_following(handle)).c_str()));
        fl_value_set_string(
            map, "belongsTo",
            fl_value_new_string(
                gid_to_hex(aria2_download_handle_get_belongs_to(handle)).c_str()));

        char* dir = aria2_download_handle_get_dir(handle);
        fl_value_set_string(map, "dir",
                            fl_value_new_string(dir == nullptr ? "" : dir));
        if (dir != nullptr) {
          aria2_free(dir);
        }
        fl_value_set_string(
            map, "numFiles",
            fl_value_new_int(aria2_download_handle_get_num_files(handle)));

        aria2_delete_download_handle(handle);
        response = success_response(map);
      }
    }
  } else if (strcmp(method, "getDownloadFiles") == 0) {
    if (self->session == nullptr) {
      response = error_response("NO_SESSION", "No active session");
    } else {
      std::string gid_hex = map_get_string(args, "gid");
      aria2_gid_t gid = aria2_hex_to_gid(gid_hex.c_str());
      aria2_download_handle_t* handle = aria2_get_download_handle(self->session, gid);
      if (handle == nullptr) {
        g_autofree gchar* message = g_strdup_printf(
            "aria2_get_download_handle returned null for gid %s", gid_hex.c_str());
        response = error_response("HANDLE_FAILED", message);
      } else {
        aria2_file_data_t* files = nullptr;
        size_t files_count = 0;
        int ret = aria2_download_handle_get_files(handle, &files, &files_count);
        FlValue* list = fl_value_new_list();
        if (ret == 0 && files != nullptr) {
          for (size_t i = 0; i < files_count; ++i) {
            fl_value_append(list, file_data_to_fl_value(files[i]));
          }
          aria2_free_file_data_array(files, files_count);
        }
        aria2_delete_download_handle(handle);
        response = success_response(list);
      }
    }
  } else if (strcmp(method, "getDownloadOption") == 0) {
    if (self->session == nullptr) {
      response = error_response("NO_SESSION", "No active session");
    } else {
      std::string gid_hex = map_get_string(args, "gid");
      std::string name = map_get_string(args, "name");
      aria2_gid_t gid = aria2_hex_to_gid(gid_hex.c_str());
      aria2_download_handle_t* handle = aria2_get_download_handle(self->session, gid);
      if (handle == nullptr) {
        g_autofree gchar* message = g_strdup_printf(
            "aria2_get_download_handle returned null for gid %s", gid_hex.c_str());
        response = error_response("HANDLE_FAILED", message);
      } else {
        char* value = aria2_download_handle_get_option(handle, name.c_str());
        if (value != nullptr) {
          response = success_response(fl_value_new_string(value));
          aria2_free(value);
        } else {
          response = null_success_response();
        }
        aria2_delete_download_handle(handle);
      }
    }
  } else if (strcmp(method, "getDownloadOptions") == 0) {
    if (self->session == nullptr) {
      response = error_response("NO_SESSION", "No active session");
    } else {
      std::string gid_hex = map_get_string(args, "gid");
      aria2_gid_t gid = aria2_hex_to_gid(gid_hex.c_str());
      aria2_download_handle_t* handle = aria2_get_download_handle(self->session, gid);
      if (handle == nullptr) {
        g_autofree gchar* message = g_strdup_printf(
            "aria2_get_download_handle returned null for gid %s", gid_hex.c_str());
        response = error_response("HANDLE_FAILED", message);
      } else {
        aria2_key_val_t* options = nullptr;
        size_t options_count = 0;
        int ret =
            aria2_download_handle_get_options(handle, &options, &options_count);
        FlValue* map = fl_value_new_map();
        if (ret == 0 && options != nullptr) {
          for (size_t i = 0; i < options_count; ++i) {
            fl_value_set_string(
                map, options[i].key == nullptr ? "" : options[i].key,
                fl_value_new_string(options[i].value == nullptr ? ""
                                                               : options[i].value));
          }
          aria2_free_key_vals(options, options_count);
        }
        aria2_delete_download_handle(handle);
        response = success_response(map);
      }
    }
  } else if (strcmp(method, "getDownloadBtMetaInfo") == 0) {
    if (self->session == nullptr) {
      response = error_response("NO_SESSION", "No active session");
    } else {
      std::string gid_hex = map_get_string(args, "gid");
      aria2_gid_t gid = aria2_hex_to_gid(gid_hex.c_str());
      aria2_download_handle_t* handle = aria2_get_download_handle(self->session, gid);
      if (handle == nullptr) {
        g_autofree gchar* message = g_strdup_printf(
            "aria2_get_download_handle returned null for gid %s", gid_hex.c_str());
        response = error_response("HANDLE_FAILED", message);
      } else {
        aria2_bt_meta_info_data_t meta =
            aria2_download_handle_get_bt_meta_info(handle);
        FlValue* map = fl_value_new_map();
        FlValue* announce_list = fl_value_new_list();
        for (size_t i = 0; i < meta.announce_list_count; ++i) {
          FlValue* tier = fl_value_new_list();
          for (size_t j = 0; j < meta.announce_list[i].count; ++j) {
            fl_value_append(
                tier,
                fl_value_new_string(meta.announce_list[i].values[j] == nullptr
                                        ? ""
                                        : meta.announce_list[i].values[j]));
          }
          fl_value_append(announce_list, tier);
        }
        fl_value_set_string(map, "announceList", announce_list);
        fl_value_set_string(map, "comment",
                            fl_value_new_string(meta.comment == nullptr
                                                    ? ""
                                                    : meta.comment));
        fl_value_set_string(map, "creationDate",
                            fl_value_new_int(meta.creation_date));
        fl_value_set_string(map, "mode",
                            fl_value_new_int(static_cast<int>(meta.mode)));
        fl_value_set_string(map, "name",
                            fl_value_new_string(meta.name == nullptr ? "" : meta.name));
        aria2_free_bt_meta_info_data(&meta);
        aria2_delete_download_handle(handle);
        response = success_response(map);
      }
    }
  } else {
    response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  }

  fl_method_call_respond(method_call, response, nullptr);
}

FlMethodResponse* get_platform_version() {
  struct utsname uname_data = {};
  uname(&uname_data);
  g_autofree gchar *version = g_strdup_printf("Linux %s", uname_data.version);
  g_autoptr(FlValue) result = fl_value_new_string(version);
  return FL_METHOD_RESPONSE(fl_method_success_response_new(result));
}

static void flutter_aria2_plugin_dispose(GObject* object) {
  auto* self = FLUTTER_ARIA2_PLUGIN(object);
  auto core = take_core_state(self);
  flutter_aria2::core::CleanupState(&core);
  put_core_state(self, std::move(core));
  if (self->channel != nullptr) {
    g_object_unref(self->channel);
    self->channel = nullptr;
  }
  G_OBJECT_CLASS(flutter_aria2_plugin_parent_class)->dispose(object);
}

static void flutter_aria2_plugin_class_init(FlutterAria2PluginClass* klass) {
  G_OBJECT_CLASS(klass)->dispose = flutter_aria2_plugin_dispose;
}

static void flutter_aria2_plugin_init(FlutterAria2Plugin* self) {
  self->session = nullptr;
  self->library_initialized = FALSE;
  self->run_loop_active.store(false);
  self->run_in_progress.store(false);
  self->channel = nullptr;
}

static void method_call_cb(FlMethodChannel* channel, FlMethodCall* method_call,
                           gpointer user_data) {
  FlutterAria2Plugin* plugin = FLUTTER_ARIA2_PLUGIN(user_data);
  flutter_aria2_plugin_handle_method_call(plugin, method_call);
}

void flutter_aria2_plugin_register_with_registrar(FlPluginRegistrar* registrar) {
  FlutterAria2Plugin* plugin = FLUTTER_ARIA2_PLUGIN(
      g_object_new(flutter_aria2_plugin_get_type(), nullptr));

  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  g_autoptr(FlMethodChannel) channel =
      fl_method_channel_new(fl_plugin_registrar_get_messenger(registrar),
                            "flutter_aria2",
                            FL_METHOD_CODEC(codec));
  plugin->channel = FL_METHOD_CHANNEL(g_object_ref(channel));
  fl_method_channel_set_method_call_handler(channel, method_call_cb,
                                            g_object_ref(plugin),
                                            g_object_unref);

  g_object_unref(plugin);
}
