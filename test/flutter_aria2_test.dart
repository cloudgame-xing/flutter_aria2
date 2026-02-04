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
