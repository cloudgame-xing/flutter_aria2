import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_aria2/flutter_aria2.dart';

/// BT Tracker 列表，自动附加到所有 BT 下载任务。
const kBtTrackers = [
  // ── UDP trackers ──
  'udp://tracker.opentrackr.org:1337/announce',
  'udp://open.tracker.cl:1337/announce',
  'udp://tracker.openbittorrent.com:6969/announce',
  'udp://open.demonii.com:1337/announce',
  'udp://open.stealth.si:80/announce',
  'udp://tracker.torrent.eu.org:451/announce',
  'udp://exodus.desync.com:6969/announce',
  'udp://tracker.moeking.me:6969/announce',
  'udp://tracker1.bt.moack.co.kr:80/announce',
  'udp://tracker.tiny-vps.com:6969/announce',
  'udp://tracker.theoks.net:6969/announce',
  'udp://tracker.bittor.pw:1337/announce',
  'udp://tracker.dump.cl:6969/announce',
  'udp://tracker.auber.moe:6969/announce',
  'udp://explodie.org:6969/announce',
  'udp://retracker01-msk-virt.corbina.net:80/announce',
  'udp://p4p.arenabg.com:1337/announce',
  // ── HTTP/HTTPS trackers ──
  'https://tracker.tamersunion.org:443/announce',
  'https://tracker.lilithraws.org:443/announce',
  'http://tracker.mywaifu.best:6969/announce',
  'http://tracker.bt4g.com:2095/announce',
  'https://tracker.loligirl.cn:443/announce',
  'http://bvarf.tracker.sh:2086/announce',
  // ── WebSocket trackers ──
  'wss://tracker.openwebtorrent.com',
];

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Flutter Aria2 Demo',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: Colors.indigo,
        useMaterial3: true,
        brightness: Brightness.light,
      ),
      darkTheme: ThemeData(
        colorSchemeSeed: Colors.indigo,
        useMaterial3: true,
        brightness: Brightness.dark,
      ),
      home: const DownloadPage(),
    );
  }
}

// ─────────────────── 下载任务模型 ───────────────────

class DownloadTask {
  final String gid;
  final String uri;
  Aria2DownloadStatus status;
  int totalLength;
  int completedLength;
  int downloadSpeed;
  int uploadSpeed;
  int connections;
  String dir;
  int numFiles;
  int errorCode;

  DownloadTask({
    required this.gid,
    required this.uri,
    this.status = Aria2DownloadStatus.waiting,
    this.totalLength = 0,
    this.completedLength = 0,
    this.downloadSpeed = 0,
    this.uploadSpeed = 0,
    this.connections = 0,
    this.dir = '',
    this.numFiles = 0,
    this.errorCode = 0,
  });

  double get progress =>
      totalLength > 0 ? completedLength / totalLength : 0.0;

  void updateFrom(Aria2DownloadInfo info) {
    status = info.status;
    totalLength = info.totalLength;
    completedLength = info.completedLength;
    downloadSpeed = info.downloadSpeed;
    uploadSpeed = info.uploadSpeed;
    connections = info.connections;
    dir = info.dir;
    numFiles = info.numFiles;
    errorCode = info.errorCode;
  }
}

// ─────────────────── 主页面 ───────────────────

class DownloadPage extends StatefulWidget {
  const DownloadPage({super.key});

  @override
  State<DownloadPage> createState() => _DownloadPageState();
}

class _DownloadPageState extends State<DownloadPage> {
  static const String _caBundleAssetPath = 'assets/certs/cacert.pem';

  final FlutterAria2 _aria2 = FlutterAria2();
  final TextEditingController _urlController = TextEditingController();
  final TextEditingController _dirController = TextEditingController();
  final List<DownloadTask> _tasks = [];
  final List<String> _logs = [];
  String? _caCertificatePath;

  bool _initialized = false;
  bool _sessionActive = false;
  Aria2GlobalStat? _globalStat;
  Timer? _refreshTimer;
  StreamSubscription<Aria2DownloadEventData>? _eventSub;

  @override
  void initState() {
    super.initState();
    // macOS 沙盒下优先使用可写临时目录，避免文件创建失败（errorCode=16）。
    _dirController.text =
        '${Directory.systemTemp.path}${Platform.pathSeparator}flutter_aria2_downloads';
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    _eventSub?.cancel();
    _aria2.dispose();
    _urlController.dispose();
    _dirController.dispose();
    super.dispose();
  }

  // ─────────── 引擎管理 ───────────

  Future<void> _initAria2() async {
    try {
      final ret = await _aria2.libraryInit();
      _addLog('libraryInit => $ret');
      if (ret != 0) {
        _showSnackBar('aria2 库初始化失败: $ret');
        return;
      }
      setState(() => _initialized = true);
      _showSnackBar('aria2 库初始化成功');
    } catch (e) {
      _addLog('libraryInit 异常: $e');
      _showSnackBar('初始化异常: $e');
    }
  }

  Future<void> _startSession() async {
    if (!_initialized) {
      _showSnackBar('请先初始化 aria2 库');
      return;
    }
    try {
      final dir = _dirController.text.trim();
      if (dir.isNotEmpty) {
        final d = Directory(dir);
        if (!d.existsSync()) d.createSync(recursive: true);
      }
      final needCustomCa = Platform.isIOS || Platform.isAndroid;
      String? caCertificatePath;
      if (needCustomCa) {
        caCertificatePath = await _ensureCaCertificatePath();
      }

      const maxConnPerServer = '16';
      const splitCount = '16';

      await _aria2.sessionNew(
        options: {
          if (dir.isNotEmpty) 'dir': dir,
          if (needCustomCa && caCertificatePath != null)
            'ca-certificate': caCertificatePath,
          // 避免同名文件/断点文件导致创建或截断失败。
          'allow-overwrite': 'true',
          'auto-file-renaming': 'true',
          'continue': 'true',
          if (needCustomCa) 'check-certificate': 'true',
          // ── 性能选项 ──
          'max-connection-per-server': maxConnPerServer, // 每个服务器最大连接数（默认1）
          'split': splitCount,               // 将文件分为N段并行下载
          'min-split-size': '1M',            // 最小分段大小
          'max-concurrent-downloads': '5',   // 最大同时下载任务数
          // ── BT 选项 ──
          'bt-tracker': kBtTrackers.join(','), // 自动附加 tracker
          'enable-dht': 'true',               // 启用 DHT
          'enable-peer-exchange': 'true',     // 启用 PEX 节点交换
          'seed-time': '0',                   // 下载完成后不做种
        },
        keepRunning: true,
      );
      final caLog =
          (Platform.isIOS && caCertificatePath != null)
              ? ', ca=$caCertificatePath'
              : '';
      _addLog('sessionNew 成功, dir=$dir$caLog');

      // 监听事件
      _eventSub = _aria2.onDownloadEvent.listen(_onDownloadEvent);

      // 启动原生后台事件循环（高效 I/O 多路复用）和定时刷新
      await _aria2.startRunLoop();
      _refreshTimer = Timer.periodic(
        const Duration(seconds: 1),
        (_) => _refreshStatus(),
      );

      setState(() => _sessionActive = true);
      _showSnackBar('会话启动成功');
    } catch (e) {
      _addLog('sessionNew 异常: $e');
      _showSnackBar('启动会话失败: $e');
    }
  }

  Future<void> _stopSession() async {
    _refreshTimer?.cancel();
    _refreshTimer = null;
    _eventSub?.cancel();
    _eventSub = null;

    // stopRunLoop 内部会 shutdown + join 后台线程
    try {
      await _aria2.stopRunLoop();
      _addLog('stopRunLoop 成功');
    } catch (e) {
      _addLog('stopRunLoop 异常: $e');
    }

    try {
      await _aria2.sessionFinal();
      _addLog('sessionFinal 成功');
    } catch (e) {
      _addLog('sessionFinal 异常: $e');
    }

    setState(() {
      _sessionActive = false;
      _tasks.clear();
      _globalStat = null;
    });
    _showSnackBar('会话已关闭');
  }

  Future<void> _deinitAria2() async {
    if (_sessionActive) await _stopSession();
    try {
      final ret = await _aria2.libraryDeinit();
      _addLog('libraryDeinit => $ret');
    } catch (e) {
      _addLog('libraryDeinit 异常: $e');
    }
    setState(() => _initialized = false);
    _showSnackBar('aria2 库已释放');
  }

  // ─────────── 事件处理 ───────────

  void _onDownloadEvent(Aria2DownloadEventData event) {
    _addLog('事件: ${event.event.name}  GID=${event.gid}');

    // 事件触发后立即刷新该任务状态
    _refreshTaskByGid(event.gid);
  }

  // ─────────── 下载操作 ───────────

  Future<void> _addDownload() async {
    final url = _urlController.text.trim();
    if (url.isEmpty) {
      _showSnackBar('请输入下载链接');
      return;
    }
    if (!_sessionActive) {
      _showSnackBar('请先启动会话');
      return;
    }

    try {
      final gid = await _aria2.addUri([url]);
      _addLog('addUri => GID=$gid');
      _urlController.clear();

      setState(() {
        _tasks.add(DownloadTask(gid: gid, uri: url));
      });
      _showSnackBar('下载已添加');
    } catch (e) {
      _addLog('addUri 异常: $e');
      _showSnackBar('添加失败: $e');
    }
  }

  Future<void> _addTorrentDownload() async {
    if (!_sessionActive) {
      _showSnackBar('请先启动会话');
      return;
    }

    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['torrent'],
        dialogTitle: '选择种子文件',
      );
      if (result == null || result.files.isEmpty) return;

      final filePath = result.files.single.path;
      if (filePath == null) return;

      final fileName = result.files.single.name;
      _addLog('选中种子文件: $filePath');

      final gid = await _aria2.addTorrent(filePath);
      _addLog('addTorrent => GID=$gid');

      setState(() {
        _tasks.add(DownloadTask(gid: gid, uri: '[Torrent] $fileName'));
      });
      _showSnackBar('种子下载已添加');
    } catch (e) {
      _addLog('addTorrent 异常: $e');
      _showSnackBar('添加种子失败: $e');
    }
  }

  Future<void> _pauseTask(DownloadTask task) async {
    try {
      await _aria2.pauseDownload(task.gid, force: true);
      _addLog('暂停 GID=${task.gid}');
    } catch (e) {
      _addLog('暂停异常: $e');
      _showSnackBar('暂停失败: $e');
    }
  }

  Future<void> _resumeTask(DownloadTask task) async {
    try {
      await _aria2.unpauseDownload(task.gid);
      _addLog('恢复 GID=${task.gid}');
    } catch (e) {
      _addLog('恢复异常: $e');
      _showSnackBar('恢复失败: $e');
    }
  }

  Future<void> _removeTask(DownloadTask task) async {
    try {
      await _aria2.removeDownload(task.gid, force: true);
      _addLog('移除 GID=${task.gid}');
      setState(() => _tasks.remove(task));
    } catch (e) {
      _addLog('移除异常: $e');
      _showSnackBar('移除失败: $e');
    }
  }

  // ─────────── 状态刷新 ───────────

  Future<void> _refreshStatus() async {
    if (!_sessionActive) return;

    try {
      final stat = await _aria2.getGlobalStat();
      if (!mounted) return;
      setState(() => _globalStat = stat);
    } catch (_) {}

    for (final task in _tasks) {
      if (task.status == Aria2DownloadStatus.complete ||
          task.status == Aria2DownloadStatus.removed) {
        continue;
      }
      await _refreshTaskByGid(task.gid);
    }
  }

  Future<void> _refreshTaskByGid(String gid) async {
    final task = _tasks.cast<DownloadTask?>().firstWhere(
          (t) => t?.gid == gid,
          orElse: () => null,
        );
    if (task == null) return;

    try {
      final info = await _aria2.getDownloadInfo(gid);
      if (!mounted) return;
      setState(() => task.updateFrom(info));
    } catch (_) {}
  }

  // ─────────── 工具方法 ───────────

  Future<String> _ensureCaCertificatePath() async {
    if (_caCertificatePath != null && File(_caCertificatePath!).existsSync()) {
      return _caCertificatePath!;
    }

    final certDir = Directory(
      '${Directory.systemTemp.path}${Platform.pathSeparator}flutter_aria2_certs',
    );
    if (!certDir.existsSync()) {
      certDir.createSync(recursive: true);
    }

    final certFile = File(
      '${certDir.path}${Platform.pathSeparator}cacert.pem',
    );
    final certAsset = await rootBundle.load(_caBundleAssetPath);
    await certFile.writeAsBytes(
      certAsset.buffer.asUint8List(),
      flush: true,
    );
    _caCertificatePath = certFile.path;
    return certFile.path;
  }

  void _addLog(String msg) {
    final now = DateTime.now();
    final ts =
        '${now.hour.toString().padLeft(2, '0')}:'
        '${now.minute.toString().padLeft(2, '0')}:'
        '${now.second.toString().padLeft(2, '0')}';
    setState(() {
      _logs.insert(0, '[$ts] $msg');
      if (_logs.length > 200) _logs.removeLast();
    });
  }

  void _showSnackBar(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(msg),
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
      ));
  }

  // ─────────── UI 构建 ───────────

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Flutter Aria2 下载管理器'),
        centerTitle: true,
      ),
      body: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Column(
          children: [
            const SizedBox(height: 8),

            // ── 引擎控制 ──
            _buildEngineControls(cs),

            const SizedBox(height: 12),

            // ── 全局统计 ──
            if (_globalStat != null) ...[
              _buildGlobalStatBar(cs),
              const SizedBox(height: 12),
            ],

            // ── 添加下载 ──
            if (_sessionActive) ...[
              _buildAddDownloadSection(cs),
              const SizedBox(height: 12),
            ],

            // ── 下载列表 + 日志 ──
            Expanded(
              child: _tasks.isEmpty && _logs.isEmpty
                  ? Center(
                      child: Text(
                        _sessionActive ? '暂无下载任务，请添加下载链接' : '请初始化 aria2 并启动会话',
                        style: TextStyle(color: cs.outline),
                      ),
                    )
                  : Column(
                      children: [
                        // 下载列表
                        if (_tasks.isNotEmpty)
                          Expanded(
                            flex: 3,
                            child: _buildTaskList(cs),
                          ),

                        // 日志
                        if (_logs.isNotEmpty) ...[
                          const Divider(),
                          Expanded(
                            flex: 2,
                            child: _buildLogPanel(cs),
                          ),
                        ],
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }

  // ── 引擎控制按钮行 ──
  Widget _buildEngineControls(ColorScheme cs) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('引擎控制', style: TextStyle(
              fontWeight: FontWeight.bold,
              color: cs.primary,
            )),
            const SizedBox(height: 4),
            // 下载目录
            Row(
              children: [
                const Text('下载目录: '),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: _dirController,
                    enabled: !_sessionActive,
                    style: const TextStyle(fontSize: 13),
                    decoration: const InputDecoration(
                      isDense: true,
                      contentPadding: EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 8,
                      ),
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  onPressed: _initialized ? null : _initAria2,
                  icon: const Icon(Icons.power_settings_new, size: 18),
                  label: const Text('初始化库'),
                ),
                FilledButton.tonalIcon(
                  onPressed:
                      _initialized && !_sessionActive ? _startSession : null,
                  icon: const Icon(Icons.play_arrow, size: 18),
                  label: const Text('启动会话'),
                ),
                OutlinedButton.icon(
                  onPressed: _sessionActive ? _stopSession : null,
                  icon: const Icon(Icons.stop, size: 18),
                  label: const Text('关闭会话'),
                ),
                OutlinedButton.icon(
                  onPressed:
                      _initialized && !_sessionActive ? _deinitAria2 : null,
                  icon: const Icon(Icons.power_off, size: 18),
                  label: const Text('释放库'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // ── 全局统计 ──
  Widget _buildGlobalStatBar(ColorScheme cs) {
    final stat = _globalStat!;
    return Card(
      color: cs.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            Icon(Icons.speed, size: 18, color: cs.onSecondaryContainer),
            const SizedBox(width: 8),
            _statChip(Icons.download, _formatSpeed(stat.downloadSpeed)),
            const SizedBox(width: 16),
            _statChip(Icons.upload, _formatSpeed(stat.uploadSpeed)),
            const Spacer(),
            _statChip(Icons.downloading, '${stat.numActive} 活跃'),
            const SizedBox(width: 12),
            _statChip(Icons.hourglass_empty, '${stat.numWaiting} 等待'),
            const SizedBox(width: 12),
            _statChip(Icons.check_circle_outline, '${stat.numStopped} 停止'),
          ],
        ),
      ),
    );
  }

  Widget _statChip(IconData icon, String label) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14),
        const SizedBox(width: 4),
        Text(label, style: const TextStyle(fontSize: 12)),
      ],
    );
  }

  // ── 添加下载 ──
  Widget _buildAddDownloadSection(ColorScheme cs) {
    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _urlController,
                decoration: InputDecoration(
                  hintText: '输入下载链接 (HTTP/HTTPS/FTP/Magnet)',
                  prefixIcon: const Icon(Icons.link),
                  border: const OutlineInputBorder(),
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 12,
                  ),
                  suffixIcon: IconButton(
                    icon: const Icon(Icons.content_paste),
                    tooltip: '从剪贴板粘贴',
                    onPressed: () async {
                      final data =
                          await Clipboard.getData(Clipboard.kTextPlain);
                      if (data?.text != null) {
                        _urlController.text = data!.text!;
                      }
                    },
                  ),
                ),
                onSubmitted: (_) => _addDownload(),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton.icon(
              onPressed: _addDownload,
              icon: const Icon(Icons.add),
              label: const Text('下载'),
            ),
            const SizedBox(width: 8),
            OutlinedButton.icon(
              onPressed: _addTorrentDownload,
              icon: const Icon(Icons.file_open, size: 18),
              label: const Text('种子文件'),
            ),
          ],
        ),
      ],
    );
  }

  // ── 下载列表 ──
  Widget _buildTaskList(ColorScheme cs) {
    return ListView.builder(
      itemCount: _tasks.length,
      itemBuilder: (context, index) {
        final task = _tasks[index];
        return _buildTaskCard(task, cs);
      },
    );
  }

  Widget _buildTaskCard(DownloadTask task, ColorScheme cs) {
    final statusColor = _statusColor(task.status, cs);
    final statusText = _statusText(task.status);
    final isActive = task.status == Aria2DownloadStatus.active;
    final isPaused = task.status == Aria2DownloadStatus.paused;
    final isWaiting = task.status == Aria2DownloadStatus.waiting;
    final isDone = task.status == Aria2DownloadStatus.complete;
    final isError = task.status == Aria2DownloadStatus.error;

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 第一行：URI + 状态
            Row(
              children: [
                Expanded(
                  child: Text(
                    task.uri,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: statusColor.withAlpha(30),
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: statusColor.withAlpha(80)),
                  ),
                  child: Text(
                    statusText,
                    style: TextStyle(
                      fontSize: 11,
                      color: statusColor,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),

            const SizedBox(height: 8),

            // 第二行：进度条
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: isDone ? 1.0 : task.progress,
                minHeight: 6,
                backgroundColor: cs.surfaceContainerHighest,
                color: isDone
                    ? Colors.green
                    : isError
                        ? cs.error
                        : cs.primary,
              ),
            ),

            const SizedBox(height: 6),

            // 第三行：详细信息 + 操作按钮
            Row(
              children: [
                // 进度百分比
                Text(
                  '${(task.progress * 100).toStringAsFixed(1)}%',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: cs.onSurface,
                  ),
                ),
                const SizedBox(width: 12),
                // 大小
                Text(
                  '${_formatSize(task.completedLength)} / ${_formatSize(task.totalLength)}',
                  style: TextStyle(fontSize: 11, color: cs.outline),
                ),
                const SizedBox(width: 12),
                // 速度
                if (isActive) ...[
                  Icon(Icons.download, size: 12, color: cs.primary),
                  const SizedBox(width: 2),
                  Text(
                    _formatSpeed(task.downloadSpeed),
                    style: TextStyle(
                      fontSize: 11,
                      color: cs.primary,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '${task.connections} 连接',
                    style: TextStyle(fontSize: 11, color: cs.outline),
                  ),
                ],
                if (isError) ...[
                  Icon(Icons.error_outline, size: 12, color: cs.error),
                  const SizedBox(width: 2),
                  Text(
                    '错误码: ${task.errorCode}',
                    style: TextStyle(fontSize: 11, color: cs.error),
                  ),
                ],

                const Spacer(),

                // GID
                Text(
                  'GID: ${task.gid.length > 8 ? '${task.gid.substring(0, 8)}...' : task.gid}',
                  style: TextStyle(
                    fontSize: 10,
                    color: cs.outline,
                    fontFamily: 'monospace',
                  ),
                ),

                const SizedBox(width: 8),

                // 操作按钮
                if (isActive)
                  _iconBtn(Icons.pause, '暂停', () => _pauseTask(task)),
                if (isPaused || isWaiting)
                  _iconBtn(Icons.play_arrow, '恢复', () => _resumeTask(task)),
                _iconBtn(Icons.close, '移除', () => _removeTask(task)),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _iconBtn(IconData icon, String tooltip, VoidCallback onPressed) {
    return SizedBox(
      width: 30,
      height: 30,
      child: IconButton(
        icon: Icon(icon, size: 16),
        tooltip: tooltip,
        onPressed: onPressed,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(),
      ),
    );
  }

  // ── 日志面板 ──
  Widget _buildLogPanel(ColorScheme cs) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.terminal, size: 14, color: cs.outline),
            const SizedBox(width: 4),
            Text(
              '事件日志',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.bold,
                color: cs.outline,
              ),
            ),
            const Spacer(),
            TextButton(
              onPressed: () => setState(() => _logs.clear()),
              child: const Text('清除', style: TextStyle(fontSize: 11)),
            ),
          ],
        ),
        Expanded(
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: cs.surfaceContainerHighest.withAlpha(100),
              borderRadius: BorderRadius.circular(8),
            ),
            child: ListView.builder(
              itemCount: _logs.length,
              itemBuilder: (context, index) {
                return Text(
                  _logs[index],
                  style: TextStyle(
                    fontSize: 11,
                    fontFamily: 'monospace',
                    color: cs.onSurfaceVariant,
                  ),
                );
              },
            ),
          ),
        ),
      ],
    );
  }

  // ─────────── 格式化工具 ───────────

  static String _formatSize(int bytes) {
    if (bytes <= 0) return '0 B';
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    int i = 0;
    double size = bytes.toDouble();
    while (size >= 1024 && i < units.length - 1) {
      size /= 1024;
      i++;
    }
    return '${size.toStringAsFixed(i == 0 ? 0 : 1)} ${units[i]}';
  }

  static String _formatSpeed(int bytesPerSec) {
    if (bytesPerSec <= 0) return '0 B/s';
    return '${_formatSize(bytesPerSec)}/s';
  }

  static Color _statusColor(Aria2DownloadStatus status, ColorScheme cs) {
    switch (status) {
      case Aria2DownloadStatus.active:
        return cs.primary;
      case Aria2DownloadStatus.waiting:
        return Colors.orange;
      case Aria2DownloadStatus.paused:
        return Colors.amber;
      case Aria2DownloadStatus.complete:
        return Colors.green;
      case Aria2DownloadStatus.error:
        return cs.error;
      case Aria2DownloadStatus.removed:
        return cs.outline;
    }
  }

  static String _statusText(Aria2DownloadStatus status) {
    switch (status) {
      case Aria2DownloadStatus.active:
        return '下载中';
      case Aria2DownloadStatus.waiting:
        return '等待中';
      case Aria2DownloadStatus.paused:
        return '已暂停';
      case Aria2DownloadStatus.complete:
        return '已完成';
      case Aria2DownloadStatus.error:
        return '出错';
      case Aria2DownloadStatus.removed:
        return '已移除';
    }
  }
}
