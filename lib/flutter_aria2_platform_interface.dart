import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'flutter_aria2.dart';
import 'flutter_aria2_method_channel.dart';

abstract class FlutterAria2Platform extends PlatformInterface {
  FlutterAria2Platform() : super(token: _token);

  static final Object _token = Object();

  static FlutterAria2Platform _instance = MethodChannelFlutterAria2();

  static FlutterAria2Platform get instance => _instance;

  static set instance(FlutterAria2Platform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  // ──────── 事件流 ────────

  Stream<Aria2DownloadEventData> get onDownloadEvent {
    throw UnimplementedError('onDownloadEvent has not been implemented.');
  }

  // ──────── 库初始化 ────────

  Future<int> libraryInit() {
    throw UnimplementedError('libraryInit() has not been implemented.');
  }

  Future<int> libraryDeinit() {
    throw UnimplementedError('libraryDeinit() has not been implemented.');
  }

  // ──────── 会话管理 ────────

  Future<void> sessionNew({
    Map<String, String>? options,
    bool keepRunning = true,
  }) {
    throw UnimplementedError('sessionNew() has not been implemented.');
  }

  Future<int> sessionFinal() {
    throw UnimplementedError('sessionFinal() has not been implemented.');
  }

  // ──────── 事件循环 ────────

  Future<int> run() {
    throw UnimplementedError('run() has not been implemented.');
  }

  /// 在原生后台线程启动持续事件循环 (ARIA2_RUN_DEFAULT)。
  Future<void> startNativeRunLoop() {
    throw UnimplementedError('startNativeRunLoop() has not been implemented.');
  }

  /// 停止原生后台事件循环。
  Future<void> stopNativeRunLoop() {
    throw UnimplementedError('stopNativeRunLoop() has not been implemented.');
  }

  // ──────── 添加下载 ────────

  Future<String> addUri(
    List<String> uris, {
    Map<String, String>? options,
    int position = -1,
  }) {
    throw UnimplementedError('addUri() has not been implemented.');
  }

  Future<String> addTorrent(
    String torrentFile, {
    List<String>? webseedUris,
    Map<String, String>? options,
    int position = -1,
  }) {
    throw UnimplementedError('addTorrent() has not been implemented.');
  }

  Future<List<String>> addMetalink(
    String metalinkFile, {
    Map<String, String>? options,
    int position = -1,
  }) {
    throw UnimplementedError('addMetalink() has not been implemented.');
  }

  // ──────── 下载控制 ────────

  Future<List<String>> getActiveDownload() {
    throw UnimplementedError('getActiveDownload() has not been implemented.');
  }

  Future<int> removeDownload(String gid, {bool force = false}) {
    throw UnimplementedError('removeDownload() has not been implemented.');
  }

  Future<int> pauseDownload(String gid, {bool force = false}) {
    throw UnimplementedError('pauseDownload() has not been implemented.');
  }

  Future<int> unpauseDownload(String gid) {
    throw UnimplementedError('unpauseDownload() has not been implemented.');
  }

  Future<int> changePosition(String gid, int pos, Aria2OffsetMode how) {
    throw UnimplementedError('changePosition() has not been implemented.');
  }

  // ──────── 选项管理 ────────

  Future<int> changeOption(String gid, Map<String, String> options) {
    throw UnimplementedError('changeOption() has not been implemented.');
  }

  Future<String?> getGlobalOption(String name) {
    throw UnimplementedError('getGlobalOption() has not been implemented.');
  }

  Future<Map<String, String>> getGlobalOptions() {
    throw UnimplementedError('getGlobalOptions() has not been implemented.');
  }

  Future<int> changeGlobalOption(Map<String, String> options) {
    throw UnimplementedError('changeGlobalOption() has not been implemented.');
  }

  // ──────── 统计 ────────

  Future<Aria2GlobalStat> getGlobalStat() {
    throw UnimplementedError('getGlobalStat() has not been implemented.');
  }

  // ──────── 关闭 ────────

  Future<int> shutdown({bool force = false}) {
    throw UnimplementedError('shutdown() has not been implemented.');
  }

  // ──────── 下载信息 ────────

  Future<Aria2DownloadInfo> getDownloadInfo(String gid) {
    throw UnimplementedError('getDownloadInfo() has not been implemented.');
  }

  Future<List<Aria2FileData>> getDownloadFiles(String gid) {
    throw UnimplementedError('getDownloadFiles() has not been implemented.');
  }

  Future<String?> getDownloadOption(String gid, String name) {
    throw UnimplementedError('getDownloadOption() has not been implemented.');
  }

  Future<Map<String, String>> getDownloadOptions(String gid) {
    throw UnimplementedError('getDownloadOptions() has not been implemented.');
  }

  Future<Aria2BtMetaInfoData> getDownloadBtMetaInfo(String gid) {
    throw UnimplementedError(
      'getDownloadBtMetaInfo() has not been implemented.',
    );
  }

  // ──────── 旧接口 ────────

  Future<String?> getPlatformVersion() {
    throw UnimplementedError('platformVersion() has not been implemented.');
  }
}
