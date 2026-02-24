import 'dart:io';

Future<void> main(List<String> args) async {
  if (args.length != 3) {
    stderr.writeln(
      'Usage: dart run build_tool/sync_deps.dart <windows|linux|macos|android|ios> <x64|arm64> <version>',
    );
    exit(64);
  }

  final platform = args[0];
  final arch = args[1];
  final version = args[2];
  await syncDeps(platform, arch, version);
}

Future<void> syncDeps(String platform, String arch, String version) async {
  // 脚本所在目录: build_tool/，上层目录即项目根目录
  final scriptDir = File(Platform.script.toFilePath()).parent;
  final projectRoot = scriptDir.parent.resolveSymbolicLinksSync();

  // 需要检查的文件列表（相对于项目根目录）
  final requiredFiles = switch (platform) {
    'windows' => [
      'windows/aria2lib/Debug/include/aria2_c_api.h',
      'windows/aria2lib/Debug/lib/libaria2_c_api.dll.a',
      'windows/aria2lib/Debug/bin/libaria2_c_api.dll',
      'windows/aria2lib/Release/include/aria2_c_api.h',
      'windows/aria2lib/Release/lib/libaria2_c_api.dll.a',
      'windows/aria2lib/Release/bin/libaria2_c_api.dll',
    ],
    'linux' => [
      'linux/aria2lib/Debug/include/aria2_c_api.h',
      'linux/aria2lib/Debug/lib/libaria2_c_api.so',
      'linux/aria2lib/Release/include/aria2_c_api.h',
      'linux/aria2lib/Release/lib/libaria2_c_api.so',
    ],
    'macos' => [
      'macos/aria2lib/Debug/include/aria2_c_api.h',
      'macos/aria2lib/Debug/lib/libaria2_c_api.dylib',
      'macos/aria2lib/Release/include/aria2_c_api.h',
      'macos/aria2lib/Release/lib/libaria2_c_api.dylib',
    ],
    'android' => [
      'android/aria2lib/Debug/include/aria2_c_api.h',
      'android/aria2lib/Debug/lib/libaria2_c_api.so',
      'android/aria2lib/Release/include/aria2_c_api.h',
      'android/aria2lib/Release/lib/libaria2_c_api.so',
    ],
    'ios' => [
      'ios/aria2lib/Debug/include/aria2_c_api.h',
      'ios/aria2lib/Debug/lib/libaria2_c_api.dylib',
      'ios/aria2lib/Release/include/aria2_c_api.h',
      'ios/aria2lib/Release/lib/libaria2_c_api.dylib',
    ],
    _ => throw Exception('Unsupported platform: $platform'),
  };

  final missingFiles = requiredFiles
      .where((f) => !File('${projectRoot}/$f').existsSync())
      .toList();

  if (missingFiles.isEmpty) {
    print('All required files exist, skipping download.');
    return;
  }

  print('Missing files:');
  for (final f in missingFiles) {
    print('  - $f');
  }
  print('Downloading...');

  final filename = platform == 'windows'
      ? 'aria2_c_api-win-$arch-v$version.tar.gz'
      : 'aria2_c_api-$platform-$arch-v$version.tar.gz';
  final url =
      'https://github.com/cloudgame-xing/aria2lib/releases/download/v$version/$filename';
  final tarGzFile = File('${scriptDir.path}/$filename');
  final aria2libDir = Directory('${projectRoot}/$platform');
  aria2libDir.createSync(recursive: true);

  // 使用 Dart HttpClient 下载文件
  final client = HttpClient();
  print('Downloading from $url');
  try {
    var uri = Uri.parse(url);
    var request = await client.getUrl(uri);
    var response = await request.close();

    // 跟随重定向（HttpClient 默认自动跟随，但 GitHub releases 可能需要多次）
    while (response.isRedirect &&
        response.headers.value(HttpHeaders.locationHeader) != null) {
      final location = response.headers.value(HttpHeaders.locationHeader)!;
      uri = uri.resolve(location);
      request = await client.getUrl(uri);
      response = await request.close();
    }

    if (response.statusCode != 200) {
      stderr.writeln(
        'Failed to download: HTTP ${response.statusCode} ${response.reasonPhrase}, url: $url',
      );
      exit(1);
    }

    final sink = tarGzFile.openWrite();
    await response.pipe(sink);
    print('Download completed.');
  } catch (e) {
    stderr.writeln('Failed to download: $e');
    exit(1);
  } finally {
    client.close();
  }

  // 解压到 windows 目录
  final extractResult = Process.runSync('tar', [
    '-xzf',
    tarGzFile.path,
    '-C',
    aria2libDir.path,
  ]);
  if (extractResult.exitCode != 0) {
    stderr.writeln('Failed to extract: ${extractResult.stderr}');
    exit(1);
  }
  print('Extraction completed.');

  // 清理下载的压缩包
  tarGzFile.deleteSync();
  print('Cleaned up temporary file.');
}
