import 'dart:io';

void main(List<String> args) {
  if (args.length != 1) {
    stderr.writeln(
      'Usage: dart run build_tool/sync_deps.dart <win|linux|mac|android|ios>',
    );
    exit(64);
  }

  switch (args.first) {
    case 'win':
      syncWin();
      break;
    case 'linux':
      syncLinux();
      break;
    case 'mac':
      syncMac();
      break;
    case 'android':
      syncAndroid();
      break;
    case 'ios':
      syncIos();
      break;
    default:
      stderr.writeln(
        'Invalid platform: ${args.first}. Expected win/linux/mac/android/ios.',
      );
      exit(64);
  }
}

void syncWin() {
  print('TODO: sync win deps');
}

void syncLinux() {
  print('TODO: sync linux deps');
}

void syncMac() {
  print('TODO: sync mac deps');
}

void syncAndroid() {
  print('TODO: sync android deps');
}

void syncIos() {
  print('TODO: sync ios deps');
}
