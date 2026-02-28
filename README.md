# flutter_aria2

A Flutter plugin that embeds the [aria2](https://aria2.github.io/) download engine via its C++ API. It provides full download management (HTTP/HTTPS/FTP, BitTorrent, Metalink) with session control, options, and real-time events on Android, iOS, Linux, macOS, and Windows.

## Disclaimer

**This project is primarily developed with AI assistance and is currently under active development. Stability is not guaranteed.** Use at your own risk.

The **example** app is intended to demonstrate usage and features only; as a day-to-day download tool it lacks many features.

## Features

- **Multiple protocols**: Add downloads by URI (HTTP/HTTPS/FTP), BitTorrent (`.torrent`), and Metalink.
- **Session & lifecycle**: Initialize the library, create/close sessions, and run the event loop (optionally in a native background thread so the UI stays responsive).
- **Download control**: Pause, unpause, remove, reorder downloads; get active download list.
- **Options**: Per-download and global options (e.g. `dir`, `max-concurrent-downloads`); get/set at runtime.
- **Events**: Stream of download events (start, pause, stop, complete, error, BT complete) for building UIs.
- **Stats & info**: Global stats (speed, active/waiting/stopped counts), per-download info (progress, speed, status), file list, and BT meta info.
- **Error handling**: Platform errors are wrapped in `Aria2Exception` with a clear `code` and `message`.

## Supported platforms

| Platform | Support | Arch        |
|----------|---------|-------------|
| Android  | ✅      | arm64, x64  |
| iOS      | ✅      | arm64       |
| Linux    | ✅      | arm64, x64  |
| macOS    | ✅      | arm64, x64  |
| Windows  | ✅      | arm64, x64  |

## Installation

Add to your `pubspec.yaml`:

```yaml
dependencies:
  flutter_aria2:
    path: ../flutter_aria2   # or use git dependency
```

Then run:

```bash
flutter pub get
```

## Quick start

```dart
import 'package:flutter_aria2/flutter_aria2.dart';

final aria2 = FlutterAria2();

// 1. Initialize and create session
await aria2.libraryInit();
await aria2.sessionNew(options: {'dir': '/path/to/downloads'});

// 2. Start the event loop (non-blocking, runs on native thread)
await aria2.startRunLoop();

// 3. Listen to download events
aria2.onDownloadEvent.listen((event) {
  print('${event.event} for gid ${event.gid}');
});

// 4. Add a download
final gid = await aria2.addUri(['https://example.com/file.zip']);
print('Started download: $gid');

// 5. Query info or control (pause/unpause/remove) as needed
final info = await aria2.getDownloadInfo(gid);
print('Progress: ${(info.progress * 100).toStringAsFixed(1)}%');

// 6. When done: stop loop, close session, deinit
await aria2.stopRunLoop();
await aria2.sessionFinal();
await aria2.libraryDeinit();
```

## API overview

| Area           | Methods / APIs |
|----------------|----------------|
| Lifecycle      | `libraryInit`, `libraryDeinit`, `sessionNew`, `sessionFinal` |
| Event loop     | `run`, `startRunLoop`, `stopRunLoop` |
| Add download   | `addUri`, `addTorrent`, `addMetalink` |
| Control        | `getActiveDownload`, `removeDownload`, `pauseDownload`, `unpauseDownload`, `changePosition` |
| Options        | `changeOption`, `getGlobalOption`, `getGlobalOptions`, `changeGlobalOption`, `getDownloadOption`, `getDownloadOptions` |
| Stats & info   | `getGlobalStat`, `getDownloadInfo`, `getDownloadFiles`, `getDownloadBtMetaInfo` |
| Events         | `onDownloadEvent` (stream) |
| Shutdown       | `shutdown` |

Data types include `Aria2DownloadInfo`, `Aria2GlobalStat`, `Aria2FileData`, `Aria2BtMetaInfoData`, `Aria2DownloadEventData`, and enums such as `Aria2DownloadStatus`, `Aria2DownloadEvent`, `Aria2OffsetMode`. Errors are thrown as `Aria2Exception`.

## License

See the repository for license information.
