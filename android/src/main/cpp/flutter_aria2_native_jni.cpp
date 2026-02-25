#include <jni.h>

#include <aria2_c_api.h>
#include "common/aria2_core.h"
#include "common/aria2_helpers.h"

#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <mutex>
#include <sstream>
#include <string>
#include <thread>
#include <vector>

namespace {

JavaVM* g_vm = nullptr;
std::mutex g_event_sink_mutex;
jobject g_event_sink = nullptr;  // Global ref to Aria2NativeManager.

constexpr const char* kErrorClassName =
    "me/junjie/xing/flutter_aria2/Aria2NativeException";

struct Aria2State : public flutter_aria2::core::RuntimeState {};

jfieldID GetNativeHandleFieldId(JNIEnv* env, jobject thiz) {
  jclass cls = env->GetObjectClass(thiz);
  return env->GetFieldID(cls, "nativeHandle", "J");
}

Aria2State* GetState(JNIEnv* env, jobject thiz) {
  jfieldID fid = GetNativeHandleFieldId(env, thiz);
  auto ptr = static_cast<Aria2State*>(reinterpret_cast<void*>(
      env->GetLongField(thiz, fid)));
  return ptr;
}

void SetState(JNIEnv* env, jobject thiz, Aria2State* state) {
  jfieldID fid = GetNativeHandleFieldId(env, thiz);
  env->SetLongField(
      thiz, fid, static_cast<jlong>(reinterpret_cast<uintptr_t>(state)));
}

std::string JStringToStdString(JNIEnv* env, jstring jstr) {
  if (jstr == nullptr) return "";
  const char* chars = env->GetStringUTFChars(jstr, nullptr);
  std::string value = chars == nullptr ? "" : chars;
  if (chars != nullptr) {
    env->ReleaseStringUTFChars(jstr, chars);
  }
  return value;
}

jobject NewInteger(JNIEnv* env, int value) {
  jclass cls = env->FindClass("java/lang/Integer");
  jmethodID ctor = env->GetMethodID(cls, "<init>", "(I)V");
  return env->NewObject(cls, ctor, static_cast<jint>(value));
}

jobject NewLong(JNIEnv* env, int64_t value) {
  jclass cls = env->FindClass("java/lang/Long");
  jmethodID ctor = env->GetMethodID(cls, "<init>", "(J)V");
  return env->NewObject(cls, ctor, static_cast<jlong>(value));
}

jobject NewBoolean(JNIEnv* env, bool value) {
  jclass cls = env->FindClass("java/lang/Boolean");
  jmethodID ctor = env->GetMethodID(cls, "<init>", "(Z)V");
  return env->NewObject(cls, ctor, static_cast<jboolean>(value));
}

jobject NewString(JNIEnv* env, const std::string& value) {
  return env->NewStringUTF(value.c_str());
}

jobject NewHashMap(JNIEnv* env) {
  jclass cls = env->FindClass("java/util/HashMap");
  jmethodID ctor = env->GetMethodID(cls, "<init>", "()V");
  return env->NewObject(cls, ctor);
}

jobject NewArrayList(JNIEnv* env) {
  jclass cls = env->FindClass("java/util/ArrayList");
  jmethodID ctor = env->GetMethodID(cls, "<init>", "()V");
  return env->NewObject(cls, ctor);
}

void HashMapPut(JNIEnv* env, jobject map, jobject key, jobject value) {
  jclass cls = env->FindClass("java/util/Map");
  jmethodID put = env->GetMethodID(
      cls, "put", "(Ljava/lang/Object;Ljava/lang/Object;)Ljava/lang/Object;");
  env->CallObjectMethod(map, put, key, value);
}

void ArrayListAdd(JNIEnv* env, jobject list, jobject value) {
  jclass cls = env->FindClass("java/util/List");
  jmethodID add = env->GetMethodID(cls, "add", "(Ljava/lang/Object;)Z");
  env->CallBooleanMethod(list, add, value);
}

jobject MapGet(JNIEnv* env, jobject map, const char* key) {
  if (map == nullptr) return nullptr;
  jclass map_cls = env->FindClass("java/util/Map");
  if (!env->IsInstanceOf(map, map_cls)) return nullptr;
  jmethodID get = env->GetMethodID(
      map_cls, "get", "(Ljava/lang/Object;)Ljava/lang/Object;");
  jstring jkey = env->NewStringUTF(key);
  jobject value = env->CallObjectMethod(map, get, jkey);
  env->DeleteLocalRef(jkey);
  return value;
}

bool IsInstanceOf(JNIEnv* env, jobject obj, const char* class_name) {
  if (obj == nullptr) return false;
  jclass cls = env->FindClass(class_name);
  return env->IsInstanceOf(obj, cls);
}

std::string MapGetString(JNIEnv* env, jobject map, const char* key,
                         const std::string& def = "") {
  jobject value = MapGet(env, map, key);
  if (!IsInstanceOf(env, value, "java/lang/String")) return def;
  return JStringToStdString(env, static_cast<jstring>(value));
}

int MapGetInt(JNIEnv* env, jobject map, const char* key, int def = 0) {
  jobject value = MapGet(env, map, key);
  if (!IsInstanceOf(env, value, "java/lang/Number")) return def;
  jclass cls = env->FindClass("java/lang/Number");
  jmethodID int_value = env->GetMethodID(cls, "intValue", "()I");
  return static_cast<int>(env->CallIntMethod(value, int_value));
}

bool MapGetBool(JNIEnv* env, jobject map, const char* key, bool def = false) {
  jobject value = MapGet(env, map, key);
  if (!IsInstanceOf(env, value, "java/lang/Boolean")) return def;
  jclass cls = env->FindClass("java/lang/Boolean");
  jmethodID bool_value = env->GetMethodID(cls, "booleanValue", "()Z");
  return env->CallBooleanMethod(value, bool_value) == JNI_TRUE;
}

jobject MapGetMap(JNIEnv* env, jobject map, const char* key) {
  jobject value = MapGet(env, map, key);
  if (!IsInstanceOf(env, value, "java/util/Map")) return nullptr;
  return value;
}

jobject MapGetList(JNIEnv* env, jobject map, const char* key) {
  jobject value = MapGet(env, map, key);
  if (!IsInstanceOf(env, value, "java/util/List")) return nullptr;
  return value;
}

std::vector<std::string> JavaListToStringVector(JNIEnv* env, jobject list) {
  std::vector<std::string> out;
  if (!IsInstanceOf(env, list, "java/util/List")) return out;
  jclass list_cls = env->FindClass("java/util/List");
  jmethodID size_id = env->GetMethodID(list_cls, "size", "()I");
  jmethodID get_id = env->GetMethodID(
      list_cls, "get", "(I)Ljava/lang/Object;");

  int size = env->CallIntMethod(list, size_id);
  out.reserve(static_cast<size_t>(size));
  for (int i = 0; i < size; ++i) {
    jobject item = env->CallObjectMethod(list, get_id, i);
    if (IsInstanceOf(env, item, "java/lang/String")) {
      out.push_back(JStringToStdString(env, static_cast<jstring>(item)));
    }
    env->DeleteLocalRef(item);
  }
  return out;
}

struct KeyValHelper {
  std::vector<std::string> keys;
  std::vector<std::string> values;
  std::vector<aria2_key_val_t> kvs;

  void FromJavaMap(JNIEnv* env, jobject map) {
    if (!IsInstanceOf(env, map, "java/util/Map")) return;
    jclass map_cls = env->FindClass("java/util/Map");
    jmethodID entry_set = env->GetMethodID(
        map_cls, "entrySet", "()Ljava/util/Set;");
    jobject set_obj = env->CallObjectMethod(map, entry_set);

    jclass set_cls = env->FindClass("java/util/Set");
    jmethodID iterator = env->GetMethodID(
        set_cls, "iterator", "()Ljava/util/Iterator;");
    jobject it = env->CallObjectMethod(set_obj, iterator);

    jclass it_cls = env->FindClass("java/util/Iterator");
    jmethodID has_next = env->GetMethodID(it_cls, "hasNext", "()Z");
    jmethodID next = env->GetMethodID(it_cls, "next", "()Ljava/lang/Object;");

    jclass entry_cls = env->FindClass("java/util/Map$Entry");
    jmethodID get_key = env->GetMethodID(entry_cls, "getKey",
                                         "()Ljava/lang/Object;");
    jmethodID get_value = env->GetMethodID(entry_cls, "getValue",
                                           "()Ljava/lang/Object;");

    while (env->CallBooleanMethod(it, has_next) == JNI_TRUE) {
      jobject entry = env->CallObjectMethod(it, next);
      jobject key = env->CallObjectMethod(entry, get_key);
      jobject value = env->CallObjectMethod(entry, get_value);
      if (IsInstanceOf(env, key, "java/lang/String") &&
          IsInstanceOf(env, value, "java/lang/String")) {
        keys.push_back(JStringToStdString(env, static_cast<jstring>(key)));
        values.push_back(JStringToStdString(env, static_cast<jstring>(value)));
      }
      env->DeleteLocalRef(key);
      env->DeleteLocalRef(value);
      env->DeleteLocalRef(entry);
    }
    env->DeleteLocalRef(it);
    env->DeleteLocalRef(set_obj);

    kvs.resize(keys.size());
    for (size_t i = 0; i < keys.size(); ++i) {
      kvs[i].key = const_cast<char*>(keys[i].c_str());
      kvs[i].value = const_cast<char*>(values[i].c_str());
    }
  }

  const aria2_key_val_t* data() const {
    return kvs.empty() ? nullptr : kvs.data();
  }
  size_t count() const { return kvs.size(); }
};

KeyValHelper OptionsFromArgs(JNIEnv* env, jobject args, const char* key) {
  KeyValHelper helper;
  jobject options = MapGetMap(env, args, key);
  helper.FromJavaMap(env, options);
  return helper;
}

void ThrowAria2Error(JNIEnv* env, const std::string& code,
                     const std::string& message) {
  if (env->ExceptionCheck()) return;
  jclass ex_cls = env->FindClass(kErrorClassName);
  if (ex_cls == nullptr) {
    jclass runtime_cls = env->FindClass("java/lang/RuntimeException");
    env->ThrowNew(runtime_cls, message.c_str());
    return;
  }
  jmethodID ctor =
      env->GetMethodID(ex_cls, "<init>", "(Ljava/lang/String;Ljava/lang/String;)V");
  if (ctor == nullptr) {
    jclass runtime_cls = env->FindClass("java/lang/RuntimeException");
    env->ThrowNew(runtime_cls, message.c_str());
    return;
  }
  jstring jcode = env->NewStringUTF(code.c_str());
  jstring jmsg = env->NewStringUTF(message.c_str());
  jobject ex = env->NewObject(ex_cls, ctor, jcode, jmsg);
  env->Throw(static_cast<jthrowable>(ex));
  env->DeleteLocalRef(jcode);
  env->DeleteLocalRef(jmsg);
  env->DeleteLocalRef(ex);
}

void EmitDownloadEvent(aria2_download_event_t event, const std::string& gid) {
  if (g_vm == nullptr) return;
  JNIEnv* env = nullptr;
  bool did_attach = false;
  if (g_vm->GetEnv(reinterpret_cast<void**>(&env), JNI_VERSION_1_6) != JNI_OK) {
    if (g_vm->AttachCurrentThread(&env, nullptr) != JNI_OK) {
      return;
    }
    did_attach = true;
  }

  jobject sink_local = nullptr;
  {
    std::lock_guard<std::mutex> lock(g_event_sink_mutex);
    if (g_event_sink != nullptr) {
      sink_local = env->NewLocalRef(g_event_sink);
    }
  }
  if (sink_local != nullptr) {
    jclass sink_cls = env->GetObjectClass(sink_local);
    jmethodID method = env->GetMethodID(
        sink_cls, "onDownloadEventFromNative", "(ILjava/lang/String;)V");
    if (method != nullptr) {
      jstring jgid = env->NewStringUTF(gid.c_str());
      env->CallVoidMethod(sink_local, method, static_cast<jint>(event), jgid);
      env->DeleteLocalRef(jgid);
    }
    env->DeleteLocalRef(sink_local);
  }

  if (did_attach) {
    g_vm->DetachCurrentThread();
  }
}

int DownloadEventCallback(aria2_session_t* /*session*/,
                          aria2_download_event_t event,
                          aria2_gid_t gid,
                          void* /*user_data*/) {
  EmitDownloadEvent(event, flutter_aria2::common::GidToHex(gid));
  return 0;
}

jobject FileDataToJavaMap(JNIEnv* env, const aria2_file_data_t& file) {
  jobject file_map = NewHashMap(env);
  HashMapPut(env, file_map, NewString(env, "index"), NewInteger(env, file.index));
  HashMapPut(env, file_map, NewString(env, "path"),
             NewString(env, file.path == nullptr ? "" : file.path));
  HashMapPut(env, file_map, NewString(env, "length"),
             NewLong(env, static_cast<int64_t>(file.length)));
  HashMapPut(env, file_map, NewString(env, "completedLength"),
             NewLong(env, static_cast<int64_t>(file.completed_length)));
  HashMapPut(env, file_map, NewString(env, "selected"),
             NewBoolean(env, file.selected != 0));

  jobject uris = NewArrayList(env);
  for (size_t i = 0; i < file.uris_count; ++i) {
    jobject uri_map = NewHashMap(env);
    HashMapPut(env, uri_map, NewString(env, "uri"),
               NewString(env, file.uris[i].uri == nullptr ? "" : file.uris[i].uri));
    HashMapPut(env, uri_map, NewString(env, "status"),
               NewInteger(env, static_cast<int>(file.uris[i].status)));
    ArrayListAdd(env, uris, uri_map);
    env->DeleteLocalRef(uri_map);
  }
  HashMapPut(env, file_map, NewString(env, "uris"), uris);
  env->DeleteLocalRef(uris);
  return file_map;
}

jobject InvokeNative(JNIEnv* env, Aria2State* state, const std::string& method,
                     jobject args) {
  if (method == "libraryInit") {
    return NewInteger(env, flutter_aria2::core::LibraryInit(state));
  }

  if (method == "libraryDeinit") {
    return NewInteger(env, flutter_aria2::core::LibraryDeinit(state));
  }

  if (method == "sessionNew") {
    if (!state->library_initialized) {
      ThrowAria2Error(env, "NOT_INITIALIZED",
                      "Call libraryInit() before sessionNew()");
      return nullptr;
    }
    if (state->session != nullptr) {
      ThrowAria2Error(env, "SESSION_EXISTS",
                      "Session already exists. Call sessionFinal() first.");
      return nullptr;
    }
    auto options = OptionsFromArgs(env, args, "options");
    bool keep_running = MapGetBool(env, args, "keepRunning", true);

    const char* error = flutter_aria2::core::SessionNew(
        state, options.data(), options.count(), keep_running,
        &DownloadEventCallback, state);
    if (error != nullptr) {
      ThrowAria2Error(env, "SESSION_FAILED", "aria2_session_new returned null");
      return nullptr;
    }
    return nullptr;
  }

  if (method == "sessionFinal") {
    if (state->session == nullptr) {
      ThrowAria2Error(env, "NO_SESSION", "No active session");
      return nullptr;
    }
    int ret = 0;
    flutter_aria2::core::SessionFinal(state, &ret);
    return NewInteger(env, ret);
  }

  if (method == "run") {
    if (state->session == nullptr) {
      ThrowAria2Error(env, "NO_SESSION", "No active session");
      return nullptr;
    }
    return NewInteger(env, flutter_aria2::core::RunOnce(state));
  }

  if (method == "startRunLoop") {
    if (state->session == nullptr) {
      ThrowAria2Error(env, "NO_SESSION", "No active session");
      return nullptr;
    }
    flutter_aria2::core::StartRunLoop(state);
    return nullptr;
  }

  if (method == "stopRunLoop") {
    flutter_aria2::core::StopRunLoop(state);
    return nullptr;
  }

  if (method == "shutdown") {
    if (state->session == nullptr) {
      ThrowAria2Error(env, "NO_SESSION", "No active session");
      return nullptr;
    }
    int force = MapGetBool(env, args, "force", false) ? 1 : 0;
    int ret = 0;
    flutter_aria2::core::Shutdown(state, force != 0, &ret);
    return NewInteger(env, ret);
  }

  if (method == "addUri") {
    if (state->session == nullptr) {
      ThrowAria2Error(env, "NO_SESSION", "No active session");
      return nullptr;
    }
    jobject uris_list = MapGetList(env, args, "uris");
    if (uris_list == nullptr) {
      ThrowAria2Error(env, "BAD_ARGS", "Missing 'uris'");
      return nullptr;
    }
    auto uris = JavaListToStringVector(env, uris_list);
    std::vector<const char*> uri_ptrs;
    uri_ptrs.reserve(uris.size());
    for (const auto& uri : uris) {
      uri_ptrs.push_back(uri.c_str());
    }
    auto options = OptionsFromArgs(env, args, "options");
    int position = MapGetInt(env, args, "position", -1);
    aria2_gid_t gid;
    int ret = aria2_add_uri(state->session, &gid, uri_ptrs.data(), uri_ptrs.size(),
                            options.data(), options.count(), position);
    if (ret != 0) {
      ThrowAria2Error(env, "ARIA2_ERROR",
                      "aria2_add_uri failed with code " + std::to_string(ret));
      return nullptr;
    }
    return NewString(env, flutter_aria2::common::GidToHex(gid));
  }

  if (method == "addTorrent") {
    if (state->session == nullptr) {
      ThrowAria2Error(env, "NO_SESSION", "No active session");
      return nullptr;
    }
    std::string torrent_file = MapGetString(env, args, "torrentFile");
    jobject ws_list = MapGetList(env, args, "webseedUris");
    auto webseeds = JavaListToStringVector(env, ws_list);
    std::vector<const char*> ws_ptrs;
    ws_ptrs.reserve(webseeds.size());
    for (const auto& s : webseeds) {
      ws_ptrs.push_back(s.c_str());
    }

    auto options = OptionsFromArgs(env, args, "options");
    int position = MapGetInt(env, args, "position", -1);
    aria2_gid_t gid;
    int ret = 0;
    if (ws_ptrs.empty()) {
      ret = aria2_add_torrent_simple(state->session, &gid, torrent_file.c_str(),
                                     options.data(), options.count(), position);
    } else {
      ret = aria2_add_torrent(state->session, &gid, torrent_file.c_str(),
                              ws_ptrs.data(), ws_ptrs.size(), options.data(),
                              options.count(), position);
    }
    if (ret != 0) {
      ThrowAria2Error(env, "ARIA2_ERROR",
                      "aria2_add_torrent failed with code " + std::to_string(ret));
      return nullptr;
    }
    return NewString(env, flutter_aria2::common::GidToHex(gid));
  }

  if (method == "addMetalink") {
    if (state->session == nullptr) {
      ThrowAria2Error(env, "NO_SESSION", "No active session");
      return nullptr;
    }
    std::string metalink_file = MapGetString(env, args, "metalinkFile");
    auto options = OptionsFromArgs(env, args, "options");
    int position = MapGetInt(env, args, "position", -1);
    aria2_gid_t* gids = nullptr;
    size_t gids_count = 0;
    int ret = aria2_add_metalink(state->session, &gids, &gids_count,
                                 metalink_file.c_str(), options.data(),
                                 options.count(), position);
    if (ret != 0) {
      if (gids != nullptr) aria2_free(gids);
      ThrowAria2Error(
          env, "ARIA2_ERROR",
          "aria2_add_metalink failed with code " + std::to_string(ret));
      return nullptr;
    }
    jobject list = NewArrayList(env);
    for (size_t i = 0; i < gids_count; ++i) {
        jobject gid_obj =
            NewString(env, flutter_aria2::common::GidToHex(gids[i]));
      ArrayListAdd(env, list, gid_obj);
      env->DeleteLocalRef(gid_obj);
    }
    if (gids != nullptr) aria2_free(gids);
    return list;
  }

  if (method == "getActiveDownload") {
    if (state->session == nullptr) {
      ThrowAria2Error(env, "NO_SESSION", "No active session");
      return nullptr;
    }
    aria2_gid_t* gids = nullptr;
    size_t gids_count = 0;
    int ret = aria2_get_active_download(state->session, &gids, &gids_count);
    if (ret != 0) {
      if (gids != nullptr) aria2_free(gids);
      ThrowAria2Error(
          env, "ARIA2_ERROR",
          "aria2_get_active_download failed with code " + std::to_string(ret));
      return nullptr;
    }
    jobject list = NewArrayList(env);
    for (size_t i = 0; i < gids_count; ++i) {
        jobject gid_obj =
            NewString(env, flutter_aria2::common::GidToHex(gids[i]));
      ArrayListAdd(env, list, gid_obj);
      env->DeleteLocalRef(gid_obj);
    }
    if (gids != nullptr) aria2_free(gids);
    return list;
  }

  if (method == "removeDownload") {
    if (state->session == nullptr) {
      ThrowAria2Error(env, "NO_SESSION", "No active session");
      return nullptr;
    }
    std::string hex = MapGetString(env, args, "gid");
    bool force = MapGetBool(env, args, "force", false);
    int ret = aria2_remove_download(state->session, aria2_hex_to_gid(hex.c_str()),
                                    force ? 1 : 0);
    return NewInteger(env, ret);
  }

  if (method == "pauseDownload") {
    if (state->session == nullptr) {
      ThrowAria2Error(env, "NO_SESSION", "No active session");
      return nullptr;
    }
    std::string hex = MapGetString(env, args, "gid");
    bool force = MapGetBool(env, args, "force", false);
    int ret = aria2_pause_download(state->session, aria2_hex_to_gid(hex.c_str()),
                                   force ? 1 : 0);
    return NewInteger(env, ret);
  }

  if (method == "unpauseDownload") {
    if (state->session == nullptr) {
      ThrowAria2Error(env, "NO_SESSION", "No active session");
      return nullptr;
    }
    std::string hex = MapGetString(env, args, "gid");
    int ret = aria2_unpause_download(state->session, aria2_hex_to_gid(hex.c_str()));
    return NewInteger(env, ret);
  }

  if (method == "changePosition") {
    if (state->session == nullptr) {
      ThrowAria2Error(env, "NO_SESSION", "No active session");
      return nullptr;
    }
    std::string hex = MapGetString(env, args, "gid");
    int pos = MapGetInt(env, args, "pos", 0);
    int how = MapGetInt(env, args, "how", 0);
    int ret = aria2_change_position(
        state->session, aria2_hex_to_gid(hex.c_str()), pos,
        static_cast<aria2_offset_mode_t>(how));
    return NewInteger(env, ret);
  }

  if (method == "changeOption") {
    if (state->session == nullptr) {
      ThrowAria2Error(env, "NO_SESSION", "No active session");
      return nullptr;
    }
    std::string hex = MapGetString(env, args, "gid");
    auto options = OptionsFromArgs(env, args, "options");
    int ret = aria2_change_option(state->session, aria2_hex_to_gid(hex.c_str()),
                                  options.data(), options.count());
    return NewInteger(env, ret);
  }

  if (method == "getGlobalOption") {
    if (state->session == nullptr) {
      ThrowAria2Error(env, "NO_SESSION", "No active session");
      return nullptr;
    }
    std::string name = MapGetString(env, args, "name");
    char* value = aria2_get_global_option(state->session, name.c_str());
    if (value == nullptr) return nullptr;
    std::string result(value);
    aria2_free(value);
    return NewString(env, result);
  }

  if (method == "getGlobalOptions") {
    if (state->session == nullptr) {
      ThrowAria2Error(env, "NO_SESSION", "No active session");
      return nullptr;
    }
    aria2_key_val_t* options = nullptr;
    size_t count = 0;
    int ret = aria2_get_global_options(state->session, &options, &count);
    if (ret != 0) {
      if (options != nullptr) aria2_free_key_vals(options, count);
      ThrowAria2Error(
          env, "ARIA2_ERROR",
          "aria2_get_global_options failed with code " + std::to_string(ret));
      return nullptr;
    }
    jobject map = NewHashMap(env);
    for (size_t i = 0; i < count; ++i) {
      HashMapPut(env, map, NewString(env, options[i].key == nullptr ? "" : options[i].key),
                 NewString(env, options[i].value == nullptr ? "" : options[i].value));
    }
    if (options != nullptr) aria2_free_key_vals(options, count);
    return map;
  }

  if (method == "changeGlobalOption") {
    if (state->session == nullptr) {
      ThrowAria2Error(env, "NO_SESSION", "No active session");
      return nullptr;
    }
    auto options = OptionsFromArgs(env, args, "options");
    int ret = aria2_change_global_option(state->session, options.data(),
                                         options.count());
    return NewInteger(env, ret);
  }

  if (method == "getGlobalStat") {
    if (state->session == nullptr) {
      ThrowAria2Error(env, "NO_SESSION", "No active session");
      return nullptr;
    }
    aria2_global_stat_t stat = aria2_get_global_stat(state->session);
    jobject map = NewHashMap(env);
    HashMapPut(env, map, NewString(env, "downloadSpeed"),
               NewLong(env, static_cast<int64_t>(stat.download_speed)));
    HashMapPut(env, map, NewString(env, "uploadSpeed"),
               NewLong(env, static_cast<int64_t>(stat.upload_speed)));
    HashMapPut(env, map, NewString(env, "numActive"),
               NewInteger(env, stat.num_active));
    HashMapPut(env, map, NewString(env, "numWaiting"),
               NewInteger(env, stat.num_waiting));
    HashMapPut(env, map, NewString(env, "numStopped"),
               NewInteger(env, stat.num_stopped));
    return map;
  }

  if (method == "getDownloadInfo") {
    if (state->session == nullptr) {
      ThrowAria2Error(env, "NO_SESSION", "No active session");
      return nullptr;
    }
    std::string hex = MapGetString(env, args, "gid");
    aria2_download_handle_t* dh =
        aria2_get_download_handle(state->session, aria2_hex_to_gid(hex.c_str()));
    if (dh == nullptr) {
      ThrowAria2Error(env, "HANDLE_FAILED",
                      "aria2_get_download_handle returned null for gid " + hex);
      return nullptr;
    }

    jobject map = NewHashMap(env);
    HashMapPut(env, map, NewString(env, "gid"), NewString(env, hex));
    HashMapPut(env, map, NewString(env, "status"),
               NewInteger(env, static_cast<int>(aria2_download_handle_get_status(dh))));
    HashMapPut(env, map, NewString(env, "totalLength"),
               NewLong(env, static_cast<int64_t>(aria2_download_handle_get_total_length(dh))));
    HashMapPut(env, map, NewString(env, "completedLength"),
               NewLong(env, static_cast<int64_t>(aria2_download_handle_get_completed_length(dh))));
    HashMapPut(env, map, NewString(env, "uploadLength"),
               NewLong(env, static_cast<int64_t>(aria2_download_handle_get_upload_length(dh))));
    HashMapPut(env, map, NewString(env, "downloadSpeed"),
               NewLong(env, static_cast<int64_t>(aria2_download_handle_get_download_speed(dh))));
    HashMapPut(env, map, NewString(env, "uploadSpeed"),
               NewLong(env, static_cast<int64_t>(aria2_download_handle_get_upload_speed(dh))));

    aria2_binary_t ih = aria2_download_handle_get_info_hash(dh);
    if (ih.data != nullptr && ih.length > 0) {
      std::ostringstream ss;
      for (size_t i = 0; i < ih.length; ++i) {
        char buf[3];
        std::snprintf(buf, sizeof(buf), "%02x", ih.data[i]);
        ss << buf;
      }
      HashMapPut(env, map, NewString(env, "infoHash"), NewString(env, ss.str()));
      aria2_free_binary(&ih);
    } else {
      HashMapPut(env, map, NewString(env, "infoHash"), NewString(env, ""));
    }

    HashMapPut(env, map, NewString(env, "pieceLength"),
               NewLong(env, static_cast<int64_t>(aria2_download_handle_get_piece_length(dh))));
    HashMapPut(env, map, NewString(env, "numPieces"),
               NewInteger(env, aria2_download_handle_get_num_pieces(dh)));
    HashMapPut(env, map, NewString(env, "connections"),
               NewInteger(env, aria2_download_handle_get_connections(dh)));
    HashMapPut(env, map, NewString(env, "errorCode"),
               NewInteger(env, aria2_download_handle_get_error_code(dh)));

    aria2_gid_t* followed_by = nullptr;
    size_t followed_count = 0;
    jobject followed_list = NewArrayList(env);
    if (aria2_download_handle_get_followed_by(dh, &followed_by, &followed_count) == 0) {
      for (size_t i = 0; i < followed_count; ++i) {
        jobject gid_obj =
            NewString(env, flutter_aria2::common::GidToHex(followed_by[i]));
        ArrayListAdd(env, followed_list, gid_obj);
        env->DeleteLocalRef(gid_obj);
      }
      if (followed_by != nullptr) aria2_free(followed_by);
    }
    HashMapPut(env, map, NewString(env, "followedBy"), followed_list);
    env->DeleteLocalRef(followed_list);

    HashMapPut(env, map, NewString(env, "following"),
               NewString(env, flutter_aria2::common::GidToHex(
                                   aria2_download_handle_get_following(dh))));
    HashMapPut(env, map, NewString(env, "belongsTo"),
               NewString(env, flutter_aria2::common::GidToHex(
                                   aria2_download_handle_get_belongs_to(dh))));

    char* dir = aria2_download_handle_get_dir(dh);
    HashMapPut(env, map, NewString(env, "dir"), NewString(env, dir == nullptr ? "" : dir));
    if (dir != nullptr) aria2_free(dir);

    HashMapPut(env, map, NewString(env, "numFiles"),
               NewInteger(env, aria2_download_handle_get_num_files(dh)));

    aria2_delete_download_handle(dh);
    return map;
  }

  if (method == "getDownloadFiles") {
    if (state->session == nullptr) {
      ThrowAria2Error(env, "NO_SESSION", "No active session");
      return nullptr;
    }
    std::string hex = MapGetString(env, args, "gid");
    aria2_download_handle_t* dh =
        aria2_get_download_handle(state->session, aria2_hex_to_gid(hex.c_str()));
    if (dh == nullptr) {
      ThrowAria2Error(env, "HANDLE_FAILED",
                      "aria2_get_download_handle returned null for gid " + hex);
      return nullptr;
    }

    aria2_file_data_t* files = nullptr;
    size_t files_count = 0;
    int ret = aria2_download_handle_get_files(dh, &files, &files_count);
    jobject list = NewArrayList(env);
    if (ret == 0 && files != nullptr) {
      for (size_t i = 0; i < files_count; ++i) {
        jobject file_map = FileDataToJavaMap(env, files[i]);
        ArrayListAdd(env, list, file_map);
        env->DeleteLocalRef(file_map);
      }
      aria2_free_file_data_array(files, files_count);
    }
    aria2_delete_download_handle(dh);
    return list;
  }

  if (method == "getDownloadOption") {
    if (state->session == nullptr) {
      ThrowAria2Error(env, "NO_SESSION", "No active session");
      return nullptr;
    }
    std::string hex = MapGetString(env, args, "gid");
    std::string name = MapGetString(env, args, "name");
    aria2_download_handle_t* dh =
        aria2_get_download_handle(state->session, aria2_hex_to_gid(hex.c_str()));
    if (dh == nullptr) {
      ThrowAria2Error(env, "HANDLE_FAILED",
                      "aria2_get_download_handle returned null for gid " + hex);
      return nullptr;
    }
    char* value = aria2_download_handle_get_option(dh, name.c_str());
    aria2_delete_download_handle(dh);
    if (value == nullptr) return nullptr;
    std::string result(value);
    aria2_free(value);
    return NewString(env, result);
  }

  if (method == "getDownloadOptions") {
    if (state->session == nullptr) {
      ThrowAria2Error(env, "NO_SESSION", "No active session");
      return nullptr;
    }
    std::string hex = MapGetString(env, args, "gid");
    aria2_download_handle_t* dh =
        aria2_get_download_handle(state->session, aria2_hex_to_gid(hex.c_str()));
    if (dh == nullptr) {
      ThrowAria2Error(env, "HANDLE_FAILED",
                      "aria2_get_download_handle returned null for gid " + hex);
      return nullptr;
    }

    aria2_key_val_t* options = nullptr;
    size_t count = 0;
    int ret = aria2_download_handle_get_options(dh, &options, &count);
    jobject map = NewHashMap(env);
    if (ret == 0 && options != nullptr) {
      for (size_t i = 0; i < count; ++i) {
        HashMapPut(env, map,
                   NewString(env, options[i].key == nullptr ? "" : options[i].key),
                   NewString(env, options[i].value == nullptr ? "" : options[i].value));
      }
      aria2_free_key_vals(options, count);
    }
    aria2_delete_download_handle(dh);
    return map;
  }

  if (method == "getDownloadBtMetaInfo") {
    if (state->session == nullptr) {
      ThrowAria2Error(env, "NO_SESSION", "No active session");
      return nullptr;
    }
    std::string hex = MapGetString(env, args, "gid");
    aria2_download_handle_t* dh =
        aria2_get_download_handle(state->session, aria2_hex_to_gid(hex.c_str()));
    if (dh == nullptr) {
      ThrowAria2Error(env, "HANDLE_FAILED",
                      "aria2_get_download_handle returned null for gid " + hex);
      return nullptr;
    }

    aria2_bt_meta_info_data_t meta = aria2_download_handle_get_bt_meta_info(dh);
    jobject map = NewHashMap(env);
    jobject announce_list = NewArrayList(env);
    for (size_t i = 0; i < meta.announce_list_count; ++i) {
      jobject tier = NewArrayList(env);
      for (size_t j = 0; j < meta.announce_list[i].count; ++j) {
        jobject url_obj = NewString(env, meta.announce_list[i].values[j] == nullptr
                                             ? ""
                                             : meta.announce_list[i].values[j]);
        ArrayListAdd(env, tier, url_obj);
        env->DeleteLocalRef(url_obj);
      }
      ArrayListAdd(env, announce_list, tier);
      env->DeleteLocalRef(tier);
    }
    HashMapPut(env, map, NewString(env, "announceList"), announce_list);
    HashMapPut(env, map, NewString(env, "comment"),
               NewString(env, meta.comment == nullptr ? "" : meta.comment));
    HashMapPut(env, map, NewString(env, "creationDate"),
               NewLong(env, static_cast<int64_t>(meta.creation_date)));
    HashMapPut(env, map, NewString(env, "mode"),
               NewInteger(env, static_cast<int>(meta.mode)));
    HashMapPut(env, map, NewString(env, "name"),
               NewString(env, meta.name == nullptr ? "" : meta.name));
    env->DeleteLocalRef(announce_list);

    aria2_free_bt_meta_info_data(&meta);
    aria2_delete_download_handle(dh);
    return map;
  }

  ThrowAria2Error(env, "NOT_IMPLEMENTED", "Method not implemented: " + method);
  return nullptr;
}

}  // namespace

extern "C" JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM* vm, void* /*reserved*/) {
  g_vm = vm;
  return JNI_VERSION_1_6;
}

extern "C" JNIEXPORT void JNICALL
Java_me_junjie_xing_flutter_1aria2_Aria2NativeManager_nativeInit(
    JNIEnv* env, jobject thiz) {
  auto* state = GetState(env, thiz);
  if (state != nullptr) {
    flutter_aria2::core::CleanupState(state);
    delete state;
  }
  SetState(env, thiz, new Aria2State());
}

extern "C" JNIEXPORT void JNICALL
Java_me_junjie_xing_flutter_1aria2_Aria2NativeManager_nativeDispose(
    JNIEnv* env, jobject thiz) {
  auto* state = GetState(env, thiz);
  if (state == nullptr) return;
  flutter_aria2::core::CleanupState(state);
  delete state;
  SetState(env, thiz, nullptr);
}

extern "C" JNIEXPORT jobject JNICALL
Java_me_junjie_xing_flutter_1aria2_Aria2NativeManager_nativeInvoke(
    JNIEnv* env, jobject thiz, jstring method, jobject arguments) {
  auto* state = GetState(env, thiz);
  if (state == nullptr) {
    ThrowAria2Error(env, "NATIVE_STATE", "Native state not initialized");
    return nullptr;
  }
  std::string method_name = JStringToStdString(env, method);
  return InvokeNative(env, state, method_name, arguments);
}

extern "C" JNIEXPORT void JNICALL
Java_me_junjie_xing_flutter_1aria2_Aria2NativeManager_nativeSetEventSink(
    JNIEnv* env, jobject /*thiz*/, jobject manager) {
  std::lock_guard<std::mutex> lock(g_event_sink_mutex);
  if (g_event_sink != nullptr) {
    env->DeleteGlobalRef(g_event_sink);
    g_event_sink = nullptr;
  }
  if (manager != nullptr) {
    g_event_sink = env->NewGlobalRef(manager);
  }
}
