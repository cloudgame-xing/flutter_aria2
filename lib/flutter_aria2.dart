
import 'flutter_aria2_platform_interface.dart';

class FlutterAria2 {
  Future<String?> getPlatformVersion() {
    return FlutterAria2Platform.instance.getPlatformVersion();
  }
}
