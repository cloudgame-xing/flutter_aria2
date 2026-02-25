#import "FlutterAria2Native.h"

#import <UIKit/UIKit.h>

#include <aria2_c_api.h>
#include "../../common/aria2_core.h"
#include "../../common/aria2_helpers.h"

#include <atomic>
#include <cstdio>
#include <sstream>
#include <string>
#include <thread>
#include <vector>

NSErrorDomain const FlutterAria2NativeErrorDomain = @"FlutterAria2NativeErrorDomain";

namespace {

using Dict = NSDictionary<NSString*, id>*;
using Array = NSArray*;

flutter_aria2::core::RuntimeState TakeCoreState(
    aria2_session_t*& session, BOOL& libraryInitialized, std::thread& runThread,
    std::atomic<bool>& runLoopActive, std::atomic<bool>& runInProgress) {
  flutter_aria2::core::RuntimeState core;
  core.session = session;
  core.library_initialized = libraryInitialized;
  core.run_thread = std::move(runThread);
  core.run_loop_active.store(runLoopActive.load());
  core.run_in_progress.store(runInProgress.load());
  return core;
}

void PutCoreState(aria2_session_t*& session, BOOL& libraryInitialized,
                  std::thread& runThread, std::atomic<bool>& runLoopActive,
                  std::atomic<bool>& runInProgress,
                  flutter_aria2::core::RuntimeState&& core) {
  session = core.session;
  libraryInitialized = core.library_initialized ? YES : NO;
  runThread = std::move(core.run_thread);
  runLoopActive.store(core.run_loop_active.load());
  runInProgress.store(core.run_in_progress.load());
}

NSError* MakeError(NSString* code, NSString* message) {
  return [NSError errorWithDomain:FlutterAria2NativeErrorDomain
                             code:1
                         userInfo:@{
                           @"code" : code,
                           NSLocalizedDescriptionKey : message,
                         }];
}

id MapGet(Dict map, NSString* key) {
  if (![map isKindOfClass:[NSDictionary class]]) {
    return nil;
  }
  id value = map[key];
  if (value == [NSNull null]) {
    return nil;
  }
  return value;
}

NSString* MapGetString(Dict map, NSString* key, NSString* def = @"") {
  id value = MapGet(map, key);
  if ([value isKindOfClass:[NSString class]]) {
    return (NSString*)value;
  }
  return def;
}

int MapGetInt(Dict map, NSString* key, int def = 0) {
  id value = MapGet(map, key);
  if ([value respondsToSelector:@selector(intValue)]) {
    return [value intValue];
  }
  return def;
}

bool MapGetBool(Dict map, NSString* key, bool def = false) {
  id value = MapGet(map, key);
  if ([value respondsToSelector:@selector(boolValue)]) {
    return [value boolValue];
  }
  return def;
}

Dict MapGetDict(Dict map, NSString* key) {
  id value = MapGet(map, key);
  if ([value isKindOfClass:[NSDictionary class]]) {
    return (Dict)value;
  }
  return nil;
}

Array MapGetArray(Dict map, NSString* key) {
  id value = MapGet(map, key);
  if ([value isKindOfClass:[NSArray class]]) {
    return (Array)value;
  }
  return nil;
}

struct KeyValHelper {
  std::vector<std::string> keys;
  std::vector<std::string> values;
  std::vector<aria2_key_val_t> kvs;

  void fromDict(Dict dict) {
    if (dict == nil) {
      return;
    }
    keys.reserve(dict.count);
    values.reserve(dict.count);
    for (id key in dict) {
      id value = dict[key];
      if (![key isKindOfClass:[NSString class]] ||
          ![value isKindOfClass:[NSString class]]) {
        continue;
      }
      keys.emplace_back([(NSString*)key UTF8String]);
      values.emplace_back([(NSString*)value UTF8String]);
    }
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

KeyValHelper OptionsFromArgs(Dict args, NSString* key) {
  KeyValHelper kv;
  kv.fromDict(MapGetDict(args, key));
  return kv;
}

NSDictionary* FileDataToNSDictionary(const aria2_file_data_t& file) {
  NSMutableArray* uris = [NSMutableArray array];
  for (size_t i = 0; i < file.uris_count; ++i) {
    [uris addObject:@{
      @"uri" : [NSString stringWithUTF8String:file.uris[i].uri == nullptr ? "" : file.uris[i].uri],
      @"status" : @(static_cast<int>(file.uris[i].status)),
    }];
  }

  return @{
    @"index" : @(file.index),
    @"path" : [NSString stringWithUTF8String:file.path == nullptr ? "" : file.path],
    @"length" : @(file.length),
    @"completedLength" : @(file.completed_length),
    @"selected" : @(file.selected != 0),
    @"uris" : uris,
  };
}

}  // namespace

@interface FlutterAria2Native () {
 @private
  aria2_session_t* _session;
  BOOL _libraryInitialized;
  std::thread _runThread;
  std::atomic<bool> _runLoopActive;
  std::atomic<bool> _runInProgress;
}
@end

@implementation FlutterAria2Native

- (instancetype)init {
  self = [super init];
  if (self) {
    _session = nullptr;
    _libraryInitialized = NO;
    _runLoopActive.store(false);
    _runInProgress.store(false);
  }
  return self;
}

- (void)dealloc {
  auto core = TakeCoreState(_session, _libraryInitialized, _runThread,
                            _runLoopActive, _runInProgress);
  flutter_aria2::core::CleanupState(&core);
  PutCoreState(_session, _libraryInitialized, _runThread, _runLoopActive,
               _runInProgress, std::move(core));
}

- (void)waitForPendingRun {
  auto core = TakeCoreState(_session, _libraryInitialized, _runThread,
                            _runLoopActive, _runInProgress);
  flutter_aria2::core::WaitForPendingRun(&core);
  PutCoreState(_session, _libraryInitialized, _runThread, _runLoopActive,
               _runInProgress, std::move(core));
}

- (void)stopRunLoopInternal {
  auto core = TakeCoreState(_session, _libraryInitialized, _runThread,
                            _runLoopActive, _runInProgress);
  flutter_aria2::core::StopRunLoop(&core);
  PutCoreState(_session, _libraryInitialized, _runThread, _runLoopActive,
               _runInProgress, std::move(core));
}

static int DownloadEventCallback(aria2_session_t* /*session*/,
                                 aria2_download_event_t event,
                                 aria2_gid_t gid,
                                 void* user_data) {
  __weak FlutterAria2Native* weakNative = (__bridge __weak FlutterAria2Native*)user_data;
  if (weakNative == nil) {
    return 0;
  }

  NSString* gidHex = [NSString
      stringWithUTF8String:flutter_aria2::common::GidToHex(gid).c_str()];
  dispatch_async(dispatch_get_main_queue(), ^{
    FlutterAria2Native* native = weakNative;
    if (native == nil || native.onDownloadEvent == nil) {
      return;
    }
    native.onDownloadEvent(static_cast<NSInteger>(event), gidHex);
  });
  return 0;
}

- (void)invokeMethod:(NSString*)method
           arguments:(NSDictionary<NSString*, id>* _Nullable)arguments
          completion:(void (^)(id _Nullable value, NSError* _Nullable error))completion {
  Dict args = [arguments isKindOfClass:[NSDictionary class]] ? arguments : @{};

  if ([method isEqualToString:@"getPlatformVersion"]) {
    completion([@"iOS " stringByAppendingString:[UIDevice currentDevice].systemVersion], nil);
    return;
  }
  if ([method isEqualToString:@"libraryInit"]) {
    auto core = TakeCoreState(_session, _libraryInitialized, _runThread,
                              _runLoopActive, _runInProgress);
    int ret = flutter_aria2::core::LibraryInit(&core);
    PutCoreState(_session, _libraryInitialized, _runThread, _runLoopActive,
                 _runInProgress, std::move(core));
    completion(@(ret), nil);
    return;
  }
  if ([method isEqualToString:@"libraryDeinit"]) {
    auto core = TakeCoreState(_session, _libraryInitialized, _runThread,
                              _runLoopActive, _runInProgress);
    int ret = flutter_aria2::core::LibraryDeinit(&core);
    PutCoreState(_session, _libraryInitialized, _runThread, _runLoopActive,
                 _runInProgress, std::move(core));
    completion(@(ret), nil);
    return;
  }
  if ([method isEqualToString:@"sessionNew"]) {
    if (!_libraryInitialized) {
      completion(nil, MakeError(@"NOT_INITIALIZED", @"Call libraryInit() before sessionNew()"));
      return;
    }
    if (_session != nullptr) {
      completion(nil, MakeError(@"SESSION_EXISTS", @"Session already exists. Call sessionFinal() first."));
      return;
    }
    KeyValHelper options = OptionsFromArgs(args, @"options");
    bool keepRunning = MapGetBool(args, @"keepRunning", true);
    auto core = TakeCoreState(_session, _libraryInitialized, _runThread,
                              _runLoopActive, _runInProgress);
    const char* error = flutter_aria2::core::SessionNew(
        &core, options.data(), options.count(), keepRunning,
        &DownloadEventCallback, (__bridge void*)self);
    PutCoreState(_session, _libraryInitialized, _runThread, _runLoopActive,
                 _runInProgress, std::move(core));
    if (error != nullptr) {
      completion(nil, MakeError(@"SESSION_FAILED", @"aria2_session_new returned null"));
      return;
    }
    completion(nil, nil);
    return;
  }
  if ([method isEqualToString:@"sessionFinal"]) {
    if (_session == nullptr) {
      completion(nil, MakeError(@"NO_SESSION", @"No active session"));
      return;
    }
    auto core = TakeCoreState(_session, _libraryInitialized, _runThread,
                              _runLoopActive, _runInProgress);
    int ret = 0;
    flutter_aria2::core::SessionFinal(&core, &ret);
    PutCoreState(_session, _libraryInitialized, _runThread, _runLoopActive,
                 _runInProgress, std::move(core));
    completion(@(ret), nil);
    return;
  }
  if ([method isEqualToString:@"run"]) {
    if (_session == nullptr) {
      completion(nil, MakeError(@"NO_SESSION", @"No active session"));
      return;
    }
    if (_runInProgress.load()) {
      completion(@1, nil);
      return;
    }
    _runInProgress.store(true);
    aria2_session_t* session = _session;
    __block FlutterAria2Native* native = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
      int ret = -1;
      try {
        ret = aria2_run(session, ARIA2_RUN_ONCE);
      } catch (...) {
        ret = -1;
      }
      native->_runInProgress.store(false);
      dispatch_async(dispatch_get_main_queue(), ^{
        completion(@(ret), nil);
      });
    });
    return;
  }
  if ([method isEqualToString:@"startRunLoop"]) {
    if (_session == nullptr) {
      completion(nil, MakeError(@"NO_SESSION", @"No active session"));
      return;
    }
    if (_runLoopActive.load()) {
      completion(nil, nil);
      return;
    }
    auto core = TakeCoreState(_session, _libraryInitialized, _runThread,
                              _runLoopActive, _runInProgress);
    flutter_aria2::core::StartRunLoop(&core);
    PutCoreState(_session, _libraryInitialized, _runThread, _runLoopActive,
                 _runInProgress, std::move(core));
    completion(nil, nil);
    return;
  }
  if ([method isEqualToString:@"stopRunLoop"]) {
    [self stopRunLoopInternal];
    completion(nil, nil);
    return;
  }
  if ([method isEqualToString:@"shutdown"]) {
    if (_session == nullptr) {
      completion(nil, MakeError(@"NO_SESSION", @"No active session"));
      return;
    }
    int force = MapGetBool(args, @"force", false) ? 1 : 0;
    auto core = TakeCoreState(_session, _libraryInitialized, _runThread,
                              _runLoopActive, _runInProgress);
    int ret = 0;
    flutter_aria2::core::Shutdown(&core, force != 0, &ret);
    PutCoreState(_session, _libraryInitialized, _runThread, _runLoopActive,
                 _runInProgress, std::move(core));
    completion(@(ret), nil);
    return;
  }
  if ([method isEqualToString:@"addUri"]) {
    if (_session == nullptr) {
      completion(nil, MakeError(@"NO_SESSION", @"No active session"));
      return;
    }
    Array uris = MapGetArray(args, @"uris");
    if (uris == nil) {
      completion(nil, MakeError(@"BAD_ARGS", @"Missing 'uris'"));
      return;
    }
    std::vector<std::string> uriStrings;
    std::vector<const char*> uriPtrs;
    uriStrings.reserve(uris.count);
    for (id item in uris) {
      if ([item isKindOfClass:[NSString class]]) {
        uriStrings.emplace_back([(NSString*)item UTF8String]);
      }
    }
    uriPtrs.reserve(uriStrings.size());
    for (const auto& item : uriStrings) {
      uriPtrs.push_back(item.c_str());
    }
    KeyValHelper options = OptionsFromArgs(args, @"options");
    int position = MapGetInt(args, @"position", -1);
    aria2_gid_t gid;
    int ret = aria2_add_uri(_session, &gid, uriPtrs.data(), uriPtrs.size(),
                            options.data(), options.count(), position);
    if (ret == 0) {
      completion([NSString stringWithUTF8String:flutter_aria2::common::GidToHex(gid)
                                                .c_str()],
                 nil);
    } else {
      completion(nil, MakeError(@"ARIA2_ERROR", [NSString stringWithFormat:@"aria2_add_uri failed with code %d", ret]));
    }
    return;
  }
  if ([method isEqualToString:@"addTorrent"]) {
    if (_session == nullptr) {
      completion(nil, MakeError(@"NO_SESSION", @"No active session"));
      return;
    }
    NSString* torrentFile = MapGetString(args, @"torrentFile");
    Array webseedUris = MapGetArray(args, @"webseedUris");
    std::vector<std::string> wsStrings;
    std::vector<const char*> wsPtrs;
    if (webseedUris != nil) {
      wsStrings.reserve(webseedUris.count);
      for (id item in webseedUris) {
        if ([item isKindOfClass:[NSString class]]) {
          wsStrings.emplace_back([(NSString*)item UTF8String]);
        }
      }
      wsPtrs.reserve(wsStrings.size());
      for (const auto& item : wsStrings) {
        wsPtrs.push_back(item.c_str());
      }
    }
    KeyValHelper options = OptionsFromArgs(args, @"options");
    int position = MapGetInt(args, @"position", -1);
    aria2_gid_t gid;
    int ret = wsPtrs.empty()
                  ? aria2_add_torrent_simple(_session, &gid, torrentFile.UTF8String,
                                             options.data(), options.count(), position)
                  : aria2_add_torrent(_session, &gid, torrentFile.UTF8String,
                                      wsPtrs.data(), wsPtrs.size(),
                                      options.data(), options.count(), position);
    if (ret == 0) {
      completion([NSString stringWithUTF8String:flutter_aria2::common::GidToHex(gid)
                                                .c_str()],
                 nil);
    } else {
      completion(nil, MakeError(@"ARIA2_ERROR", [NSString stringWithFormat:@"aria2_add_torrent failed with code %d", ret]));
    }
    return;
  }
  if ([method isEqualToString:@"addMetalink"]) {
    if (_session == nullptr) {
      completion(nil, MakeError(@"NO_SESSION", @"No active session"));
      return;
    }
    NSString* metalinkFile = MapGetString(args, @"metalinkFile");
    KeyValHelper options = OptionsFromArgs(args, @"options");
    int position = MapGetInt(args, @"position", -1);
    aria2_gid_t* gids = nullptr;
    size_t gidsCount = 0;
    int ret = aria2_add_metalink(_session, &gids, &gidsCount, metalinkFile.UTF8String,
                                 options.data(), options.count(), position);
    if (ret == 0) {
      NSMutableArray* gidList = [NSMutableArray array];
      for (size_t i = 0; i < gidsCount; ++i) {
        [gidList addObject:[NSString
                               stringWithUTF8String:flutter_aria2::common::GidToHex(gids[i])
                                                        .c_str()]];
      }
      if (gids != nullptr) aria2_free(gids);
      completion(gidList, nil);
    } else {
      if (gids != nullptr) aria2_free(gids);
      completion(nil, MakeError(@"ARIA2_ERROR", [NSString stringWithFormat:@"aria2_add_metalink failed with code %d", ret]));
    }
    return;
  }
  if ([method isEqualToString:@"getActiveDownload"]) {
    if (_session == nullptr) {
      completion(nil, MakeError(@"NO_SESSION", @"No active session"));
      return;
    }
    aria2_gid_t* gids = nullptr;
    size_t gidsCount = 0;
    int ret = aria2_get_active_download(_session, &gids, &gidsCount);
    if (ret == 0) {
      NSMutableArray* gidList = [NSMutableArray array];
      for (size_t i = 0; i < gidsCount; ++i) {
        [gidList addObject:[NSString
                               stringWithUTF8String:flutter_aria2::common::GidToHex(gids[i])
                                                        .c_str()]];
      }
      if (gids != nullptr) aria2_free(gids);
      completion(gidList, nil);
    } else {
      if (gids != nullptr) aria2_free(gids);
      completion(nil, MakeError(@"ARIA2_ERROR", [NSString stringWithFormat:@"aria2_get_active_download failed with code %d", ret]));
    }
    return;
  }
  if ([method isEqualToString:@"removeDownload"]) {
    if (_session == nullptr) {
      completion(nil, MakeError(@"NO_SESSION", @"No active session"));
      return;
    }
    NSString* hex = MapGetString(args, @"gid");
    bool force = MapGetBool(args, @"force", false);
    completion(@(aria2_remove_download(_session, aria2_hex_to_gid(hex.UTF8String), force ? 1 : 0)), nil);
    return;
  }
  if ([method isEqualToString:@"pauseDownload"]) {
    if (_session == nullptr) {
      completion(nil, MakeError(@"NO_SESSION", @"No active session"));
      return;
    }
    NSString* hex = MapGetString(args, @"gid");
    bool force = MapGetBool(args, @"force", false);
    completion(@(aria2_pause_download(_session, aria2_hex_to_gid(hex.UTF8String), force ? 1 : 0)), nil);
    return;
  }
  if ([method isEqualToString:@"unpauseDownload"]) {
    if (_session == nullptr) {
      completion(nil, MakeError(@"NO_SESSION", @"No active session"));
      return;
    }
    NSString* hex = MapGetString(args, @"gid");
    completion(@(aria2_unpause_download(_session, aria2_hex_to_gid(hex.UTF8String))), nil);
    return;
  }
  if ([method isEqualToString:@"changePosition"]) {
    if (_session == nullptr) {
      completion(nil, MakeError(@"NO_SESSION", @"No active session"));
      return;
    }
    NSString* hex = MapGetString(args, @"gid");
    int pos = MapGetInt(args, @"pos", 0);
    int how = MapGetInt(args, @"how", 0);
    int ret = aria2_change_position(_session, aria2_hex_to_gid(hex.UTF8String), pos,
                                    static_cast<aria2_offset_mode_t>(how));
    completion(@(ret), nil);
    return;
  }
  if ([method isEqualToString:@"changeOption"]) {
    if (_session == nullptr) {
      completion(nil, MakeError(@"NO_SESSION", @"No active session"));
      return;
    }
    NSString* hex = MapGetString(args, @"gid");
    KeyValHelper options = OptionsFromArgs(args, @"options");
    int ret = aria2_change_option(_session, aria2_hex_to_gid(hex.UTF8String),
                                  options.data(), options.count());
    completion(@(ret), nil);
    return;
  }
  if ([method isEqualToString:@"getGlobalOption"]) {
    if (_session == nullptr) {
      completion(nil, MakeError(@"NO_SESSION", @"No active session"));
      return;
    }
    NSString* name = MapGetString(args, @"name");
    char* value = aria2_get_global_option(_session, name.UTF8String);
    if (value != nullptr) {
      completion([NSString stringWithUTF8String:value], nil);
      aria2_free(value);
    } else {
      completion(nil, nil);
    }
    return;
  }
  if ([method isEqualToString:@"getGlobalOptions"]) {
    if (_session == nullptr) {
      completion(nil, MakeError(@"NO_SESSION", @"No active session"));
      return;
    }
    aria2_key_val_t* options = nullptr;
    size_t optionsCount = 0;
    int ret = aria2_get_global_options(_session, &options, &optionsCount);
    if (ret == 0) {
      NSMutableDictionary* map = [NSMutableDictionary dictionary];
      for (size_t i = 0; i < optionsCount; ++i) {
        NSString* key = [NSString stringWithUTF8String:options[i].key == nullptr ? "" : options[i].key];
        NSString* value = [NSString stringWithUTF8String:options[i].value == nullptr ? "" : options[i].value];
        map[key] = value;
      }
      if (options != nullptr) aria2_free_key_vals(options, optionsCount);
      completion(map, nil);
    } else {
      if (options != nullptr) aria2_free_key_vals(options, optionsCount);
      completion(nil, MakeError(@"ARIA2_ERROR", [NSString stringWithFormat:@"aria2_get_global_options failed with code %d", ret]));
    }
    return;
  }
  if ([method isEqualToString:@"changeGlobalOption"]) {
    if (_session == nullptr) {
      completion(nil, MakeError(@"NO_SESSION", @"No active session"));
      return;
    }
    KeyValHelper options = OptionsFromArgs(args, @"options");
    completion(@(aria2_change_global_option(_session, options.data(), options.count())), nil);
    return;
  }
  if ([method isEqualToString:@"getGlobalStat"]) {
    if (_session == nullptr) {
      completion(nil, MakeError(@"NO_SESSION", @"No active session"));
      return;
    }
    aria2_global_stat_t stat = aria2_get_global_stat(_session);
    completion(@{
      @"downloadSpeed" : @(stat.download_speed),
      @"uploadSpeed" : @(stat.upload_speed),
      @"numActive" : @(stat.num_active),
      @"numWaiting" : @(stat.num_waiting),
      @"numStopped" : @(stat.num_stopped),
    }, nil);
    return;
  }
  if ([method isEqualToString:@"getDownloadInfo"]) {
    if (_session == nullptr) {
      completion(nil, MakeError(@"NO_SESSION", @"No active session"));
      return;
    }
    NSString* hex = MapGetString(args, @"gid");
    aria2_download_handle_t* dh =
        aria2_get_download_handle(_session, aria2_hex_to_gid(hex.UTF8String));
    if (dh == nullptr) {
      completion(nil, MakeError(@"HANDLE_FAILED",
                                [NSString stringWithFormat:@"aria2_get_download_handle returned null for gid %@", hex]));
      return;
    }
    NSMutableDictionary* map = [NSMutableDictionary dictionary];
    map[@"gid"] = hex;
    map[@"status"] = @(static_cast<int>(aria2_download_handle_get_status(dh)));
    map[@"totalLength"] = @(aria2_download_handle_get_total_length(dh));
    map[@"completedLength"] = @(aria2_download_handle_get_completed_length(dh));
    map[@"uploadLength"] = @(aria2_download_handle_get_upload_length(dh));
    map[@"downloadSpeed"] = @(aria2_download_handle_get_download_speed(dh));
    map[@"uploadSpeed"] = @(aria2_download_handle_get_upload_speed(dh));

    aria2_binary_t infoHash = aria2_download_handle_get_info_hash(dh);
    if (infoHash.data != nullptr && infoHash.length > 0) {
      std::ostringstream ss;
      for (size_t i = 0; i < infoHash.length; ++i) {
        char buf[3];
        snprintf(buf, sizeof(buf), "%02x", infoHash.data[i]);
        ss << buf;
      }
      map[@"infoHash"] = [NSString stringWithUTF8String:ss.str().c_str()];
      aria2_free_binary(&infoHash);
    } else {
      map[@"infoHash"] = @"";
    }

    map[@"pieceLength"] = @(aria2_download_handle_get_piece_length(dh));
    map[@"numPieces"] = @(aria2_download_handle_get_num_pieces(dh));
    map[@"connections"] = @(aria2_download_handle_get_connections(dh));
    map[@"errorCode"] = @(aria2_download_handle_get_error_code(dh));

    aria2_gid_t* followedByGids = nullptr;
    size_t followedByCount = 0;
    NSMutableArray* followedBy = [NSMutableArray array];
    if (aria2_download_handle_get_followed_by(dh, &followedByGids, &followedByCount) == 0) {
      for (size_t i = 0; i < followedByCount; ++i) {
        [followedBy addObject:[NSString
                                  stringWithUTF8String:flutter_aria2::common::GidToHex(
                                                           followedByGids[i])
                                                           .c_str()]];
      }
      if (followedByGids != nullptr) aria2_free(followedByGids);
    }
    map[@"followedBy"] = followedBy;
    map[@"following"] = [NSString
        stringWithUTF8String:flutter_aria2::common::GidToHex(
                                 aria2_download_handle_get_following(dh))
                                 .c_str()];
    map[@"belongsTo"] = [NSString
        stringWithUTF8String:flutter_aria2::common::GidToHex(
                                 aria2_download_handle_get_belongs_to(dh))
                                 .c_str()];

    char* dir = aria2_download_handle_get_dir(dh);
    map[@"dir"] = [NSString stringWithUTF8String:dir == nullptr ? "" : dir];
    if (dir != nullptr) aria2_free(dir);
    map[@"numFiles"] = @(aria2_download_handle_get_num_files(dh));

    aria2_delete_download_handle(dh);
    completion(map, nil);
    return;
  }
  if ([method isEqualToString:@"getDownloadFiles"]) {
    if (_session == nullptr) {
      completion(nil, MakeError(@"NO_SESSION", @"No active session"));
      return;
    }
    NSString* hex = MapGetString(args, @"gid");
    aria2_download_handle_t* dh =
        aria2_get_download_handle(_session, aria2_hex_to_gid(hex.UTF8String));
    if (dh == nullptr) {
      completion(nil, MakeError(@"HANDLE_FAILED",
                                [NSString stringWithFormat:@"aria2_get_download_handle returned null for gid %@", hex]));
      return;
    }
    aria2_file_data_t* files = nullptr;
    size_t filesCount = 0;
    int ret = aria2_download_handle_get_files(dh, &files, &filesCount);
    NSMutableArray* list = [NSMutableArray array];
    if (ret == 0 && files != nullptr) {
      for (size_t i = 0; i < filesCount; ++i) {
        [list addObject:FileDataToNSDictionary(files[i])];
      }
      aria2_free_file_data_array(files, filesCount);
    }
    aria2_delete_download_handle(dh);
    completion(list, nil);
    return;
  }
  if ([method isEqualToString:@"getDownloadOption"]) {
    if (_session == nullptr) {
      completion(nil, MakeError(@"NO_SESSION", @"No active session"));
      return;
    }
    NSString* hex = MapGetString(args, @"gid");
    NSString* name = MapGetString(args, @"name");
    aria2_download_handle_t* dh =
        aria2_get_download_handle(_session, aria2_hex_to_gid(hex.UTF8String));
    if (dh == nullptr) {
      completion(nil, MakeError(@"HANDLE_FAILED",
                                [NSString stringWithFormat:@"aria2_get_download_handle returned null for gid %@", hex]));
      return;
    }
    char* value = aria2_download_handle_get_option(dh, name.UTF8String);
    if (value != nullptr) {
      completion([NSString stringWithUTF8String:value], nil);
      aria2_free(value);
    } else {
      completion(nil, nil);
    }
    aria2_delete_download_handle(dh);
    return;
  }
  if ([method isEqualToString:@"getDownloadOptions"]) {
    if (_session == nullptr) {
      completion(nil, MakeError(@"NO_SESSION", @"No active session"));
      return;
    }
    NSString* hex = MapGetString(args, @"gid");
    aria2_download_handle_t* dh =
        aria2_get_download_handle(_session, aria2_hex_to_gid(hex.UTF8String));
    if (dh == nullptr) {
      completion(nil, MakeError(@"HANDLE_FAILED",
                                [NSString stringWithFormat:@"aria2_get_download_handle returned null for gid %@", hex]));
      return;
    }
    aria2_key_val_t* options = nullptr;
    size_t optionsCount = 0;
    int ret = aria2_download_handle_get_options(dh, &options, &optionsCount);
    NSMutableDictionary* map = [NSMutableDictionary dictionary];
    if (ret == 0 && options != nullptr) {
      for (size_t i = 0; i < optionsCount; ++i) {
        NSString* key = [NSString stringWithUTF8String:options[i].key == nullptr ? "" : options[i].key];
        NSString* value = [NSString stringWithUTF8String:options[i].value == nullptr ? "" : options[i].value];
        map[key] = value;
      }
      aria2_free_key_vals(options, optionsCount);
    }
    aria2_delete_download_handle(dh);
    completion(map, nil);
    return;
  }
  if ([method isEqualToString:@"getDownloadBtMetaInfo"]) {
    if (_session == nullptr) {
      completion(nil, MakeError(@"NO_SESSION", @"No active session"));
      return;
    }
    NSString* hex = MapGetString(args, @"gid");
    aria2_download_handle_t* dh =
        aria2_get_download_handle(_session, aria2_hex_to_gid(hex.UTF8String));
    if (dh == nullptr) {
      completion(nil, MakeError(@"HANDLE_FAILED",
                                [NSString stringWithFormat:@"aria2_get_download_handle returned null for gid %@", hex]));
      return;
    }
    aria2_bt_meta_info_data_t meta = aria2_download_handle_get_bt_meta_info(dh);
    NSMutableArray* announceList = [NSMutableArray array];
    for (size_t i = 0; i < meta.announce_list_count; ++i) {
      NSMutableArray* tier = [NSMutableArray array];
      for (size_t j = 0; j < meta.announce_list[i].count; ++j) {
        [tier addObject:[NSString stringWithUTF8String:
                         meta.announce_list[i].values[j] == nullptr ? "" : meta.announce_list[i].values[j]]];
      }
      [announceList addObject:tier];
    }
    NSDictionary* map = @{
      @"announceList" : announceList,
      @"comment" : [NSString stringWithUTF8String:meta.comment == nullptr ? "" : meta.comment],
      @"creationDate" : @(meta.creation_date),
      @"mode" : @(static_cast<int>(meta.mode)),
      @"name" : [NSString stringWithUTF8String:meta.name == nullptr ? "" : meta.name],
    };
    aria2_free_bt_meta_info_data(&meta);
    aria2_delete_download_handle(dh);
    completion(map, nil);
    return;
  }

  completion(nil, MakeError(@"NOT_IMPLEMENTED", @"Method is not implemented on native side"));
}

@end
