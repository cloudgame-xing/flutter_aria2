import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'flutter_aria2_platform_interface.dart';

/// An implementation of [FlutterAria2Platform] that uses method channels.
class MethodChannelFlutterAria2 extends FlutterAria2Platform {
  /// The method channel used to interact with the native platform.
  @visibleForTesting
  final methodChannel = const MethodChannel('flutter_aria2');

  @override
  Future<String?> getPlatformVersion() async {
    final version = await methodChannel.invokeMethod<String>('getPlatformVersion');
    return version;
  }
}
