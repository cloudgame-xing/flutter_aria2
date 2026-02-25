import 'package:flutter/services.dart';

import 'flutter_aria2_platform_interface.dart';

// ──────────────────────────── Enums ────────────────────────────

/// aria2 下载事件类型，对应 C API 的 aria2_download_event_t
enum Aria2DownloadEvent {
  /// 下载开始
  onDownloadStart,

  /// 下载暂停
  onDownloadPause,

  /// 下载停止
  onDownloadStop,

  /// 下载完成
  onDownloadComplete,

  /// 下载出错
  onDownloadError,

  /// BT 下载完成
  onBtDownloadComplete,
}

/// aria2 下载状态，对应 C API 的 aria2_download_status_t
enum Aria2DownloadStatus {
  /// 正在下载
  active,

  /// 等待中
  waiting,

  /// 已暂停
  paused,

  /// 已完成
  complete,

  /// 出错
  error,

  /// 已移除
  removed,
}

/// 队列位置偏移模式，对应 C API 的 aria2_offset_mode_t
enum Aria2OffsetMode {
  /// 绝对位置
  set,

  /// 相对当前位置
  cur,

  /// 相对末尾
  end,
}

/// URI 状态，对应 C API 的 aria2_uri_status_t
enum Aria2UriStatus {
  /// 已使用
  used,

  /// 等待中
  waiting,
}

/// BT 文件模式，对应 C API 的 aria2_bt_file_mode_t
enum Aria2BtFileMode {
  /// 无
  none,

  /// 单文件
  single,

  /// 多文件
  multi,
}

// ──────────────────────────── Data Classes ────────────────────────────

/// aria2 插件抛出的异常，统一包装平台错误（如 [PlatformException]）。
///
/// 调用 [FlutterAria2] 方法时，若原生层返回错误（如 NO_SESSION、NOT_INITIALIZED、
/// ARIA2_ERROR 等），会抛出本异常而非静默返回默认值。
class Aria2Exception implements Exception {
  /// 错误码，与原生层一致（如 NO_SESSION、NOT_INITIALIZED、SESSION_EXISTS、ARIA2_ERROR 等）。
  final String code;

  /// 人类可读的错误描述。
  final String message;

  /// 原始平台异常（若有），便于调试或需要时访问 details。
  final PlatformException? platformException;

  const Aria2Exception({
    required this.code,
    required this.message,
    this.platformException,
  });

  /// 从 [PlatformException] 构造。
  factory Aria2Exception.fromPlatform(PlatformException e) {
    return Aria2Exception(
      code: e.code ?? 'UNKNOWN',
      message: e.message ?? e.details?.toString() ?? 'Unknown platform error',
      platformException: e,
    );
  }

  @override
  String toString() => 'Aria2Exception($code: $message)';
}

/// 下载事件数据
class Aria2DownloadEventData {
  /// 事件类型
  final Aria2DownloadEvent event;

  /// 下载 GID（十六进制字符串）
  final String gid;

  const Aria2DownloadEventData({required this.event, required this.gid});

  factory Aria2DownloadEventData.fromMap(Map<String, dynamic> map) {
    // C API 中事件值从 1 开始
    final eventIndex = (map['event'] as int) - 1;
    return Aria2DownloadEventData(
      event: Aria2DownloadEvent.values[eventIndex],
      gid: map['gid'] as String,
    );
  }

  @override
  String toString() => 'Aria2DownloadEventData(event: $event, gid: $gid)';
}

/// 全局统计信息
class Aria2GlobalStat {
  /// 总下载速度（字节/秒）
  final int downloadSpeed;

  /// 总上传速度（字节/秒）
  final int uploadSpeed;

  /// 活跃下载数
  final int numActive;

  /// 等待下载数
  final int numWaiting;

  /// 已停止下载数
  final int numStopped;

  const Aria2GlobalStat({
    required this.downloadSpeed,
    required this.uploadSpeed,
    required this.numActive,
    required this.numWaiting,
    required this.numStopped,
  });

  factory Aria2GlobalStat.fromMap(Map<String, dynamic> map) {
    return Aria2GlobalStat(
      downloadSpeed: map['downloadSpeed'] as int,
      uploadSpeed: map['uploadSpeed'] as int,
      numActive: map['numActive'] as int,
      numWaiting: map['numWaiting'] as int,
      numStopped: map['numStopped'] as int,
    );
  }

  @override
  String toString() =>
      'Aria2GlobalStat(dl: $downloadSpeed, ul: $uploadSpeed, '
      'active: $numActive, waiting: $numWaiting, stopped: $numStopped)';
}

/// URI 数据
class Aria2UriData {
  final String uri;
  final Aria2UriStatus status;

  const Aria2UriData({required this.uri, required this.status});

  factory Aria2UriData.fromMap(Map<String, dynamic> map) {
    return Aria2UriData(
      uri: map['uri'] as String,
      status: Aria2UriStatus.values[map['status'] as int],
    );
  }

  @override
  String toString() => 'Aria2UriData(uri: $uri, status: $status)';
}

/// 文件数据
class Aria2FileData {
  /// 文件索引（从 1 开始）
  final int index;

  /// 文件路径
  final String path;

  /// 文件总大小（字节）
  final int length;

  /// 已完成大小（字节）
  final int completedLength;

  /// 是否被选中下载
  final bool selected;

  /// URI 列表
  final List<Aria2UriData> uris;

  const Aria2FileData({
    required this.index,
    required this.path,
    required this.length,
    required this.completedLength,
    required this.selected,
    required this.uris,
  });

  factory Aria2FileData.fromMap(Map<String, dynamic> map) {
    final urisList = (map['uris'] as List?) ?? [];
    return Aria2FileData(
      index: map['index'] as int,
      path: map['path'] as String,
      length: map['length'] as int,
      completedLength: map['completedLength'] as int,
      selected: map['selected'] as bool,
      uris: urisList
          .map((u) => Aria2UriData.fromMap(Map<String, dynamic>.from(u as Map)))
          .toList(),
    );
  }

  @override
  String toString() =>
      'Aria2FileData(index: $index, path: $path, '
      'length: $length, completed: $completedLength)';
}

/// BT 元信息
class Aria2BtMetaInfoData {
  /// Tracker 列表
  final List<List<String>> announceList;

  /// 注释
  final String comment;

  /// 创建日期（UNIX 时间戳）
  final int creationDate;

  /// 文件模式
  final Aria2BtFileMode mode;

  /// 种子名称
  final String name;

  const Aria2BtMetaInfoData({
    required this.announceList,
    required this.comment,
    required this.creationDate,
    required this.mode,
    required this.name,
  });

  factory Aria2BtMetaInfoData.fromMap(Map<String, dynamic> map) {
    final rawList = (map['announceList'] as List?) ?? [];
    final announces = rawList
        .map((tier) => (tier as List).map((s) => s as String).toList())
        .toList();

    return Aria2BtMetaInfoData(
      announceList: announces,
      comment: map['comment'] as String? ?? '',
      creationDate: map['creationDate'] as int? ?? 0,
      mode: Aria2BtFileMode.values[map['mode'] as int? ?? 0],
      name: map['name'] as String? ?? '',
    );
  }

  @override
  String toString() => 'Aria2BtMetaInfoData(name: $name, mode: $mode)';
}

/// 下载信息（聚合 download handle 的常用属性）
class Aria2DownloadInfo {
  /// 下载 GID
  final String gid;

  /// 下载状态
  final Aria2DownloadStatus status;

  /// 总大小（字节）
  final int totalLength;

  /// 已完成大小（字节）
  final int completedLength;

  /// 已上传大小（字节）
  final int uploadLength;

  /// 下载速度（字节/秒）
  final int downloadSpeed;

  /// 上传速度（字节/秒）
  final int uploadSpeed;

  /// Info hash（十六进制）
  final String infoHash;

  /// 分片大小
  final int pieceLength;

  /// 分片数量
  final int numPieces;

  /// 连接数
  final int connections;

  /// 错误码
  final int errorCode;

  /// 后续下载 GID 列表
  final List<String> followedBy;

  /// 前驱下载 GID
  final String following;

  /// 所属下载 GID
  final String belongsTo;

  /// 下载目录
  final String dir;

  /// 文件数量
  final int numFiles;

  const Aria2DownloadInfo({
    required this.gid,
    required this.status,
    required this.totalLength,
    required this.completedLength,
    required this.uploadLength,
    required this.downloadSpeed,
    required this.uploadSpeed,
    required this.infoHash,
    required this.pieceLength,
    required this.numPieces,
    required this.connections,
    required this.errorCode,
    required this.followedBy,
    required this.following,
    required this.belongsTo,
    required this.dir,
    required this.numFiles,
  });

  factory Aria2DownloadInfo.fromMap(Map<String, dynamic> map) {
    return Aria2DownloadInfo(
      gid: map['gid'] as String? ?? '',
      status: Aria2DownloadStatus.values[map['status'] as int? ?? 0],
      totalLength: map['totalLength'] as int? ?? 0,
      completedLength: map['completedLength'] as int? ?? 0,
      uploadLength: map['uploadLength'] as int? ?? 0,
      downloadSpeed: map['downloadSpeed'] as int? ?? 0,
      uploadSpeed: map['uploadSpeed'] as int? ?? 0,
      infoHash: map['infoHash'] as String? ?? '',
      pieceLength: map['pieceLength'] as int? ?? 0,
      numPieces: map['numPieces'] as int? ?? 0,
      connections: map['connections'] as int? ?? 0,
      errorCode: map['errorCode'] as int? ?? 0,
      followedBy: ((map['followedBy'] as List?) ?? [])
          .map((e) => e as String)
          .toList(),
      following: map['following'] as String? ?? '',
      belongsTo: map['belongsTo'] as String? ?? '',
      dir: map['dir'] as String? ?? '',
      numFiles: map['numFiles'] as int? ?? 0,
    );
  }

  /// 下载进度 (0.0 ~ 1.0)
  double get progress =>
      totalLength > 0 ? completedLength / totalLength : 0.0;

  @override
  String toString() =>
      'Aria2DownloadInfo(gid: $gid, status: $status, '
      '${(progress * 100).toStringAsFixed(1)}%, '
      'dl: $downloadSpeed, ul: $uploadSpeed)';
}

// ──────────────────────────── Main API ────────────────────────────

/// Flutter aria2 插件主类。
///
/// 通过 MethodChannel 调用原生 aria2 C API，提供完整的下载管理能力。
///
/// 基本使用流程：
/// ```dart
/// final aria2 = FlutterAria2();
/// await aria2.libraryInit();
/// await aria2.sessionNew();
/// aria2.startRunLoop(); // 启动事件循环
/// final gid = await aria2.addUri(['https://example.com/file.zip']);
/// // ... 监听事件、查询状态 ...
/// aria2.stopRunLoop();
/// await aria2.sessionFinal();
/// await aria2.libraryDeinit();
/// ```
class FlutterAria2 {
  // ──────── 事件流 ────────

  /// 下载事件流。
  ///
  /// 当下载状态发生变化（开始、暂停、停止、完成、出错等）时触发。
  Stream<Aria2DownloadEventData> get onDownloadEvent =>
      FlutterAria2Platform.instance.onDownloadEvent;

  // ──────── 库初始化 ────────

  /// 初始化 aria2 库。必须在任何其他操作前调用。
  ///
  /// 返回 0 表示成功。
  Future<int> libraryInit() {
    return FlutterAria2Platform.instance.libraryInit();
  }

  /// 反初始化 aria2 库。所有 session 关闭后调用。
  ///
  /// 返回 0 表示成功。
  Future<int> libraryDeinit() {
    return FlutterAria2Platform.instance.libraryDeinit();
  }

  // ──────── 会话管理 ────────

  /// 创建新的 aria2 会话。
  ///
  /// [options] 会话选项，如 `{'dir': '/downloads', 'max-concurrent-downloads': '5'}`。
  /// [keepRunning] 是否在所有下载完成后保持运行。
  Future<void> sessionNew({
    Map<String, String>? options,
    bool keepRunning = true,
  }) {
    return FlutterAria2Platform.instance.sessionNew(
      options: options,
      keepRunning: keepRunning,
    );
  }

  /// 关闭当前会话。
  ///
  /// 返回 0 表示成功。
  Future<int> sessionFinal() {
    return FlutterAria2Platform.instance.sessionFinal();
  }

  // ──────── 事件循环 ────────

  /// 运行一次 aria2 事件循环迭代（ARIA2_RUN_ONCE 模式）。
  ///
  /// 返回 1 表示还有未完成的下载，返回 0 表示所有下载已完成。
  /// 推荐使用 [startRunLoop] 自动定期调用。
  Future<int> run() {
    return FlutterAria2Platform.instance.run();
  }

  /// 在原生后台线程启动持续事件循环。
  ///
  /// 内部使用 `aria2_run(session, ARIA2_RUN_DEFAULT)`，通过高效的 I/O
  /// 多路复用持续处理网络事件，下载速度与原生 aria2 一致。
  /// 调用后立即返回，不会阻塞 UI。
  Future<void> startRunLoop() {
    return FlutterAria2Platform.instance.startNativeRunLoop();
  }

  /// 停止后台事件循环。
  Future<void> stopRunLoop() {
    return FlutterAria2Platform.instance.stopNativeRunLoop();
  }

  // ──────── 添加下载 ────────

  /// 添加 URI 下载。
  ///
  /// [uris] 下载链接列表（多个链接指向同一资源时用于多源下载）。
  /// [options] 下载选项。
  /// [position] 在队列中的位置，-1 表示末尾。
  ///
  /// 返回下载 GID（十六进制字符串）。
  Future<String> addUri(
    List<String> uris, {
    Map<String, String>? options,
    int position = -1,
  }) {
    return FlutterAria2Platform.instance.addUri(
      uris,
      options: options,
      position: position,
    );
  }

  /// 添加种子下载。
  ///
  /// [torrentFile] 种子文件路径。
  /// [webseedUris] Web seed URI 列表。
  /// [options] 下载选项。
  /// [position] 在队列中的位置，-1 表示末尾。
  ///
  /// 返回下载 GID（十六进制字符串）。
  Future<String> addTorrent(
    String torrentFile, {
    List<String>? webseedUris,
    Map<String, String>? options,
    int position = -1,
  }) {
    return FlutterAria2Platform.instance.addTorrent(
      torrentFile,
      webseedUris: webseedUris,
      options: options,
      position: position,
    );
  }

  /// 添加 Metalink 下载。
  ///
  /// [metalinkFile] Metalink 文件路径。
  /// [options] 下载选项。
  /// [position] 在队列中的位置，-1 表示末尾。
  ///
  /// 返回下载 GID 列表（十六进制字符串）。
  Future<List<String>> addMetalink(
    String metalinkFile, {
    Map<String, String>? options,
    int position = -1,
  }) {
    return FlutterAria2Platform.instance.addMetalink(
      metalinkFile,
      options: options,
      position: position,
    );
  }

  // ──────── 下载控制 ────────

  /// 获取所有活跃下载的 GID 列表。
  Future<List<String>> getActiveDownload() {
    return FlutterAria2Platform.instance.getActiveDownload();
  }

  /// 移除下载。
  ///
  /// [gid] 下载 GID。
  /// [force] 是否强制移除（不等待任务结束）。
  ///
  /// 返回 0 表示成功。
  Future<int> removeDownload(String gid, {bool force = false}) {
    return FlutterAria2Platform.instance.removeDownload(gid, force: force);
  }

  /// 暂停下载。
  ///
  /// [gid] 下载 GID。
  /// [force] 是否强制暂停。
  ///
  /// 返回 0 表示成功。
  Future<int> pauseDownload(String gid, {bool force = false}) {
    return FlutterAria2Platform.instance.pauseDownload(gid, force: force);
  }

  /// 恢复下载。
  ///
  /// [gid] 下载 GID。
  ///
  /// 返回 0 表示成功。
  Future<int> unpauseDownload(String gid) {
    return FlutterAria2Platform.instance.unpauseDownload(gid);
  }

  /// 修改下载在队列中的位置。
  ///
  /// [gid] 下载 GID。
  /// [pos] 目标位置。
  /// [how] 偏移模式。
  ///
  /// 返回新的位置。
  Future<int> changePosition(String gid, int pos, Aria2OffsetMode how) {
    return FlutterAria2Platform.instance.changePosition(gid, pos, how);
  }

  // ──────── 选项管理 ────────

  /// 修改指定下载的选项。
  ///
  /// [gid] 下载 GID。
  /// [options] 要修改的选项。
  ///
  /// 返回 0 表示成功。
  Future<int> changeOption(String gid, Map<String, String> options) {
    return FlutterAria2Platform.instance.changeOption(gid, options);
  }

  /// 获取指定全局选项的值。
  ///
  /// [name] 选项名称。
  Future<String?> getGlobalOption(String name) {
    return FlutterAria2Platform.instance.getGlobalOption(name);
  }

  /// 获取所有全局选项。
  Future<Map<String, String>> getGlobalOptions() {
    return FlutterAria2Platform.instance.getGlobalOptions();
  }

  /// 修改全局选项。
  ///
  /// [options] 要修改的选项。
  ///
  /// 返回 0 表示成功。
  Future<int> changeGlobalOption(Map<String, String> options) {
    return FlutterAria2Platform.instance.changeGlobalOption(options);
  }

  // ──────── 统计与状态 ────────

  /// 获取全局下载统计信息。
  Future<Aria2GlobalStat> getGlobalStat() {
    return FlutterAria2Platform.instance.getGlobalStat();
  }

  // ──────── 关闭 ────────

  /// 关闭 aria2。
  ///
  /// [force] 是否强制关闭。
  ///
  /// 返回 0 表示成功。
  Future<int> shutdown({bool force = false}) {
    return FlutterAria2Platform.instance.shutdown(force: force);
  }

  // ──────── 下载信息查询 ────────

  /// 获取下载的详细信息。
  ///
  /// [gid] 下载 GID。
  Future<Aria2DownloadInfo> getDownloadInfo(String gid) {
    return FlutterAria2Platform.instance.getDownloadInfo(gid);
  }

  /// 获取下载的文件列表。
  ///
  /// [gid] 下载 GID。
  Future<List<Aria2FileData>> getDownloadFiles(String gid) {
    return FlutterAria2Platform.instance.getDownloadFiles(gid);
  }

  /// 获取下载的指定选项值。
  ///
  /// [gid] 下载 GID。
  /// [name] 选项名称。
  Future<String?> getDownloadOption(String gid, String name) {
    return FlutterAria2Platform.instance.getDownloadOption(gid, name);
  }

  /// 获取下载的所有选项。
  ///
  /// [gid] 下载 GID。
  Future<Map<String, String>> getDownloadOptions(String gid) {
    return FlutterAria2Platform.instance.getDownloadOptions(gid);
  }

  /// 获取下载的 BT 元信息。
  ///
  /// [gid] 下载 GID。
  Future<Aria2BtMetaInfoData> getDownloadBtMetaInfo(String gid) {
    return FlutterAria2Platform.instance.getDownloadBtMetaInfo(gid);
  }

  // ──────── 工具方法 ────────

  /// 获取平台版本信息。
  Future<String?> getPlatformVersion() {
    return FlutterAria2Platform.instance.getPlatformVersion();
  }

  /// 释放资源，停止事件循环。
  Future<void> dispose() {
    return stopRunLoop();
  }
}
