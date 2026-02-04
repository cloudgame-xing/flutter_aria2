import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'flutter_aria2_method_channel.dart';

abstract class FlutterAria2Platform extends PlatformInterface {
  /// Constructs a FlutterAria2Platform.
  FlutterAria2Platform() : super(token: _token);

  static final Object _token = Object();

  static FlutterAria2Platform _instance = MethodChannelFlutterAria2();

  /// The default instance of [FlutterAria2Platform] to use.
  ///
  /// Defaults to [MethodChannelFlutterAria2].
  static FlutterAria2Platform get instance => _instance;

  /// Platform-specific implementations should set this with their own
  /// platform-specific class that extends [FlutterAria2Platform] when
  /// they register themselves.
  static set instance(FlutterAria2Platform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  Future<String?> getPlatformVersion() {
    throw UnimplementedError('platformVersion() has not been implemented.');
  }
}
