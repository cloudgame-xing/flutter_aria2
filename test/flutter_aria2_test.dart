import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_aria2/flutter_aria2.dart';
import 'package:flutter_aria2/flutter_aria2_platform_interface.dart';
import 'package:flutter_aria2/flutter_aria2_method_channel.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class MockFlutterAria2Platform
    with MockPlatformInterfaceMixin
    implements FlutterAria2Platform {
  @override
  Future<String?> getPlatformVersion() => Future.value('42');

  @override
  Stream<Aria2DownloadEventData> get onDownloadEvent => Stream.empty();

  @override
  Future<int> libraryInit() => Future.value(0);

  @override
  Future<int> libraryDeinit() => Future.value(0);

  @override
  Future<void> sessionNew({
    Map<String, String>? options,
    bool keepRunning = true,
  }) =>
      Future.value();

  @override
  Future<int> sessionFinal() => Future.value(0);

  @override
  Future<int> run() => Future.value(0);

  @override
  Future<void> startNativeRunLoop() => Future.value();

  @override
  Future<void> stopNativeRunLoop() => Future.value();

  @override
  Future<String> addUri(
    List<String> uris, {
    Map<String, String>? options,
    int position = -1,
  }) =>
      Future.value('');

  @override
  Future<String> addTorrent(
    String torrentFile, {
    List<String>? webseedUris,
    Map<String, String>? options,
    int position = -1,
  }) =>
      Future.value('');

  @override
  Future<List<String>> addMetalink(
    String metalinkFile, {
    Map<String, String>? options,
    int position = -1,
  }) =>
      Future.value([]);

  @override
  Future<List<String>> getActiveDownload() => Future.value([]);

  @override
  Future<int> removeDownload(String gid, {bool force = false}) =>
      Future.value(0);

  @override
  Future<int> pauseDownload(String gid, {bool force = false}) =>
      Future.value(0);

  @override
  Future<int> unpauseDownload(String gid) => Future.value(0);

  @override
  Future<int> changePosition(String gid, int pos, Aria2OffsetMode how) =>
      Future.value(0);

  @override
  Future<int> changeOption(String gid, Map<String, String> options) =>
      Future.value(0);

  @override
  Future<String?> getGlobalOption(String name) => Future.value(null);

  @override
  Future<Map<String, String>> getGlobalOptions() => Future.value({});

  @override
  Future<int> changeGlobalOption(Map<String, String> options) =>
      Future.value(0);

  @override
  Future<Aria2GlobalStat> getGlobalStat() => Future.value(
        const Aria2GlobalStat(
          downloadSpeed: 0,
          uploadSpeed: 0,
          numActive: 0,
          numWaiting: 0,
          numStopped: 0,
        ),
      );

  @override
  Future<int> shutdown({bool force = false}) => Future.value(0);

  @override
  Future<Aria2DownloadInfo> getDownloadInfo(String gid) =>
      Future.value(Aria2DownloadInfo.fromMap({}));

  @override
  Future<List<Aria2FileData>> getDownloadFiles(String gid) =>
      Future.value([]);

  @override
  Future<String?> getDownloadOption(String gid, String name) =>
      Future.value(null);

  @override
  Future<Map<String, String>> getDownloadOptions(String gid) =>
      Future.value({});

  @override
  Future<Aria2BtMetaInfoData> getDownloadBtMetaInfo(String gid) =>
      Future.value(const Aria2BtMetaInfoData(
        announceList: [],
        comment: '',
        creationDate: 0,
        mode: Aria2BtFileMode.none,
        name: '',
      ));
}

void main() {
  final FlutterAria2Platform initialPlatform = FlutterAria2Platform.instance;

  test('$MethodChannelFlutterAria2 is the default instance', () {
    expect(initialPlatform, isInstanceOf<MethodChannelFlutterAria2>());
  });

  test('getPlatformVersion', () async {
    FlutterAria2 flutterAria2Plugin = FlutterAria2();
    MockFlutterAria2Platform fakePlatform = MockFlutterAria2Platform();
    FlutterAria2Platform.instance = fakePlatform;

    expect(await flutterAria2Plugin.getPlatformVersion(), '42');
  });
}
