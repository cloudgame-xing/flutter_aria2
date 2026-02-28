# flutter_aria2

基于 [aria2](https://aria2.github.io/) C++ API的 Flutter 插件，在 Android、iOS、Linux、macOS 和 Windows 上提供完整的下载管理能力（HTTP/HTTPS/FTP、BitTorrent、Metalink），支持会话控制、选项配置与实时事件。

## 免责声明

**本项目代码主要由 AI 辅助完成，且目前仍在开发中，稳定性无法保证。** 请自行承担使用风险。

**example** 主要用于演示用法和功能，作为日常下载工具会有大量功能上的缺失。

## 功能特性

- **多协议支持**：通过 URI（HTTP/HTTPS/FTP）、BitTorrent（`.torrent`）和 Metalink 添加下载任务。
- **会话与生命周期**：初始化库、创建/关闭会话，并可选择在原生后台线程中运行事件循环，保持 UI 流畅。
- **下载控制**：暂停、恢复、移除、调整队列顺序；获取活跃下载列表。
- **选项管理**：支持按任务与全局选项（如 `dir`、`max-concurrent-downloads`），运行时可查询与修改。
- **事件流**：下载事件流（开始、暂停、停止、完成、错误、BT 完成），便于构建界面。
- **统计与详情**：全局统计（速度、活跃/等待/已停止数量）、单任务详情（进度、速度、状态）、文件列表及 BT 元信息。
- **错误处理**：平台错误统一封装为 `Aria2Exception`，提供明确的 `code` 与 `message`。

## 支持平台

| 平台     | 支持 | 架构        |
|----------|------|-------------|
| Android  | ✅   | arm64, x64  |
| iOS      | ✅   | arm64       |
| Linux    | ✅   | arm64, x64  |
| macOS    | ✅   | arm64, x64  |
| Windows  | ✅   | arm64, x64  |

## 安装

在 `pubspec.yaml` 中添加：

```yaml
dependencies:
  flutter_aria2:
    path: ../flutter_aria2   # 或使用 git 依赖
```

然后执行：

```bash
flutter pub get
```

## 快速开始

```dart
import 'package:flutter_aria2/flutter_aria2.dart';

final aria2 = FlutterAria2();

// 1. 初始化并创建会话
await aria2.libraryInit();
await aria2.sessionNew(options: {'dir': '/path/to/downloads'});

// 2. 启动事件循环（非阻塞，在原生线程运行）
await aria2.startRunLoop();

// 3. 监听下载事件
aria2.onDownloadEvent.listen((event) {
  print('${event.event} for gid ${event.gid}');
});

// 4. 添加下载
final gid = await aria2.addUri(['https://example.com/file.zip']);
print('Started download: $gid');

// 5. 按需查询信息或控制（暂停/恢复/移除）
final info = await aria2.getDownloadInfo(gid);
print('Progress: ${(info.progress * 100).toStringAsFixed(1)}%');

// 6. 结束时：停止循环、关闭会话、反初始化
await aria2.stopRunLoop();
await aria2.sessionFinal();
await aria2.libraryDeinit();
```

## API 概览

| 分类           | 方法 / API |
|----------------|------------|
| 生命周期       | `libraryInit`、`libraryDeinit`、`sessionNew`、`sessionFinal` |
| 事件循环       | `run`、`startRunLoop`、`stopRunLoop` |
| 添加下载       | `addUri`、`addTorrent`、`addMetalink` |
| 下载控制       | `getActiveDownload`、`removeDownload`、`pauseDownload`、`unpauseDownload`、`changePosition` |
| 选项           | `changeOption`、`getGlobalOption`、`getGlobalOptions`、`changeGlobalOption`、`getDownloadOption`、`getDownloadOptions` |
| 统计与详情     | `getGlobalStat`、`getDownloadInfo`、`getDownloadFiles`、`getDownloadBtMetaInfo` |
| 事件           | `onDownloadEvent`（流） |
| 关闭           | `shutdown` |

数据类型包括 `Aria2DownloadInfo`、`Aria2GlobalStat`、`Aria2FileData`、`Aria2BtMetaInfoData`、`Aria2DownloadEventData`，以及枚举如 `Aria2DownloadStatus`、`Aria2DownloadEvent`、`Aria2OffsetMode`。错误以 `Aria2Exception` 抛出。

## 许可证

请参见仓库中的许可证信息。
