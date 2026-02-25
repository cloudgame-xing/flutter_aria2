import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'flutter_aria2.dart';
import 'flutter_aria2_platform_interface.dart';

/// 基于 [MethodChannel] 的 [FlutterAria2Platform] 实现。
///
/// 错误处理：原生层通过 [PlatformException] 返回错误时，统一包装为 [Aria2Exception] 抛出，
/// 不再使用默认值静默吞错；仅当协议明确允许 null 的接口（如 [getGlobalOption]）才返回 null。
class MethodChannelFlutterAria2 extends FlutterAria2Platform {
  /// 与原生平台通信的 MethodChannel。
  @visibleForTesting
  final methodChannel = const MethodChannel('flutter_aria2');

  final StreamController<Aria2DownloadEventData> _eventController =
      StreamController<Aria2DownloadEventData>.broadcast();

  bool _handlerRegistered = false;

  void _ensureHandler() {
    if (!_handlerRegistered) {
      _handlerRegistered = true;
      methodChannel.setMethodCallHandler(_handleNativeCall);
    }
  }

  Future<dynamic> _handleNativeCall(MethodCall call) async {
    switch (call.method) {
      case 'onDownloadEvent':
        final args = Map<String, dynamic>.from(call.arguments as Map);
        _eventController.add(Aria2DownloadEventData.fromMap(args));
        break;
    }
    return null;
  }

  /// 调用原生方法，将 [PlatformException] 包装为 [Aria2Exception] 抛出。
  Future<T?> _invoke<T>(String method, [Map<String, dynamic>? arguments]) async {
    try {
      return await methodChannel.invokeMethod<T>(method, arguments);
    } on PlatformException catch (e) {
      throw Aria2Exception.fromPlatform(e);
    }
  }

  /// 调用原生方法并要求非 null 结果，否则抛出 [Aria2Exception]。
  Future<T> _invokeRequired<T>(String method, [Map<String, dynamic>? arguments]) async {
    final result = await _invoke<T>(method, arguments);
    if (result == null) {
      throw Aria2Exception(
        code: 'UNKNOWN',
        message: 'Platform returned null for $method',
      );
    }
    return result;
  }

  // ──────── 事件流 ────────

  @override
  Stream<Aria2DownloadEventData> get onDownloadEvent {
    _ensureHandler();
    return _eventController.stream;
  }

  // ──────── 库初始化 ────────

  @override
  Future<int> libraryInit() async {
    _ensureHandler();
    final result = await _invokeRequired<int>('libraryInit');
    return result;
  }

  @override
  Future<int> libraryDeinit() async {
    final result = await _invokeRequired<int>('libraryDeinit');
    return result;
  }

  // ──────── 会话管理 ────────

  @override
  Future<void> sessionNew({
    Map<String, String>? options,
    bool keepRunning = true,
  }) async {
    await _invoke<void>('sessionNew', {
      'options': options,
      'keepRunning': keepRunning,
    });
  }

  @override
  Future<int> sessionFinal() async {
    final result = await _invokeRequired<int>('sessionFinal');
    return result;
  }

  // ──────── 事件循环 ────────

  @override
  Future<int> run() async {
    final result = await _invokeRequired<int>('run');
    return result;
  }

  @override
  Future<void> startNativeRunLoop() async {
    await _invoke<void>('startRunLoop');
  }

  @override
  Future<void> stopNativeRunLoop() async {
    await _invoke<void>('stopRunLoop');
  }

  // ──────── 添加下载 ────────

  @override
  Future<String> addUri(
    List<String> uris, {
    Map<String, String>? options,
    int position = -1,
  }) async {
    final result = await _invokeRequired<String>('addUri', {
      'uris': uris,
      'options': options,
      'position': position,
    });
    return result;
  }

  @override
  Future<String> addTorrent(
    String torrentFile, {
    List<String>? webseedUris,
    Map<String, String>? options,
    int position = -1,
  }) async {
    final result = await _invokeRequired<String>('addTorrent', {
      'torrentFile': torrentFile,
      'webseedUris': webseedUris,
      'options': options,
      'position': position,
    });
    return result;
  }

  @override
  Future<List<String>> addMetalink(
    String metalinkFile, {
    Map<String, String>? options,
    int position = -1,
  }) async {
    final result = await _invokeRequired<List>('addMetalink', {
      'metalinkFile': metalinkFile,
      'options': options,
      'position': position,
    });
    return result.cast<String>();
  }

  // ──────── 下载控制 ────────

  @override
  Future<List<String>> getActiveDownload() async {
    final result = await _invokeRequired<List>('getActiveDownload');
    return result.cast<String>();
  }

  @override
  Future<int> removeDownload(String gid, {bool force = false}) async {
    final result = await _invokeRequired<int>('removeDownload', {
      'gid': gid,
      'force': force,
    });
    return result;
  }

  @override
  Future<int> pauseDownload(String gid, {bool force = false}) async {
    final result = await _invokeRequired<int>('pauseDownload', {
      'gid': gid,
      'force': force,
    });
    return result;
  }

  @override
  Future<int> unpauseDownload(String gid) async {
    final result = await _invokeRequired<int>('unpauseDownload', {'gid': gid});
    return result;
  }

  @override
  Future<int> changePosition(String gid, int pos, Aria2OffsetMode how) async {
    final result = await _invokeRequired<int>('changePosition', {
      'gid': gid,
      'pos': pos,
      'how': how.index,
    });
    return result;
  }

  // ──────── 选项管理 ────────

  @override
  Future<int> changeOption(String gid, Map<String, String> options) async {
    final result = await _invokeRequired<int>('changeOption', {
      'gid': gid,
      'options': options,
    });
    return result;
  }

  @override
  Future<String?> getGlobalOption(String name) async {
    final result = await _invoke<String>('getGlobalOption', {'name': name});
    return result;
  }

  @override
  Future<Map<String, String>> getGlobalOptions() async {
    final result = await _invokeRequired<Map>('getGlobalOptions');
    return Map<String, String>.from(result);
  }

  @override
  Future<int> changeGlobalOption(Map<String, String> options) async {
    final result = await _invokeRequired<int>(
      'changeGlobalOption',
      {'options': options},
    );
    return result;
  }

  // ──────── 统计 ────────

  @override
  Future<Aria2GlobalStat> getGlobalStat() async {
    final result = await _invokeRequired<Map>('getGlobalStat');
    return Aria2GlobalStat.fromMap(Map<String, dynamic>.from(result));
  }

  // ──────── 关闭 ────────

  @override
  Future<int> shutdown({bool force = false}) async {
    final result = await _invokeRequired<int>('shutdown', {'force': force});
    return result;
  }

  // ──────── 下载信息 ────────

  @override
  Future<Aria2DownloadInfo> getDownloadInfo(String gid) async {
    final result = await _invokeRequired<Map>('getDownloadInfo', {'gid': gid});
    return Aria2DownloadInfo.fromMap(Map<String, dynamic>.from(result));
  }

  @override
  Future<List<Aria2FileData>> getDownloadFiles(String gid) async {
    final result = await _invokeRequired<List>('getDownloadFiles', {'gid': gid});
    return result
        .map((f) => Aria2FileData.fromMap(Map<String, dynamic>.from(f as Map)))
        .toList();
  }

  @override
  Future<String?> getDownloadOption(String gid, String name) async {
    final result = await _invoke<String>(
      'getDownloadOption',
      {'gid': gid, 'name': name},
    );
    return result;
  }

  @override
  Future<Map<String, String>> getDownloadOptions(String gid) async {
    final result = await _invokeRequired<Map>('getDownloadOptions', {'gid': gid});
    return Map<String, String>.from(result);
  }

  @override
  Future<Aria2BtMetaInfoData> getDownloadBtMetaInfo(String gid) async {
    final result =
        await _invokeRequired<Map>('getDownloadBtMetaInfo', {'gid': gid});
    return Aria2BtMetaInfoData.fromMap(Map<String, dynamic>.from(result));
  }

  // ──────── 旧接口 ────────

  @override
  Future<String?> getPlatformVersion() async {
    final version = await _invoke<String>('getPlatformVersion');
    return version;
  }
}
