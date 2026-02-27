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
  // 全平台统一为 platform/aria2lib/arch/（arch 为 arm64 或 x64），iOS 仅 arm64 也保留该层
  final aria2libArch = '$platform/aria2lib/$arch';
  final requiredFiles = switch (platform) {
    'windows' => [
      '$aria2libArch/Debug/include/aria2_c_api.h',
      '$aria2libArch/Debug/lib/libaria2_c_api.dll.a',
      '$aria2libArch/Debug/bin/libaria2_c_api.dll',
      '$aria2libArch/Release/include/aria2_c_api.h',
      '$aria2libArch/Release/lib/libaria2_c_api.dll.a',
      '$aria2libArch/Release/bin/libaria2_c_api.dll',
    ],
    'linux' => [
      '$aria2libArch/Debug/include/aria2_c_api.h',
      '$aria2libArch/Debug/lib/libaria2_c_api.so',
      '$aria2libArch/Release/include/aria2_c_api.h',
      '$aria2libArch/Release/lib/libaria2_c_api.so',
    ],
    'macos' => [
      '$aria2libArch/Debug/include/aria2_c_api.h',
      '$aria2libArch/Debug/lib/libaria2_c_api.dylib',
      '$aria2libArch/Release/include/aria2_c_api.h',
      '$aria2libArch/Release/lib/libaria2_c_api.dylib',
    ],
    'android' => [
      '$aria2libArch/Debug/include/aria2_c_api.h',
      '$aria2libArch/Debug/lib/libaria2_c_api.so',
      '$aria2libArch/Release/include/aria2_c_api.h',
      '$aria2libArch/Release/lib/libaria2_c_api.so',
    ],
    'ios' => [
      '$aria2libArch/Debug/include/aria2_c_api.h',
      '$aria2libArch/Debug/lib/libaria2_c_api.dylib',
      '$aria2libArch/Release/include/aria2_c_api.h',
      '$aria2libArch/Release/lib/libaria2_c_api.dylib',
    ],
    _ => throw Exception('Unsupported platform: $platform'),
  };

  final missingFiles = requiredFiles
      .where((f) => !File('$projectRoot/$f').existsSync())
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

  final filename = 'aria2_c_api-$platform-$arch-v$version.tar.gz';
  final url =
      'https://github.com/cloudgame-xing/aria2lib/releases/download/v$version/$filename';
  final tarGzFile = File('$projectRoot/build_tool/$filename');
  final extractDir = Directory('$projectRoot/$platform/aria2lib/$arch');
  Directory('$projectRoot/$platform').createSync(recursive: true);
  extractDir.createSync(recursive: true);

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
      print('Redirecting to $location');
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

  // 解压：tarball 内含顶层 aria2lib/，统一解压到 platform/aria2lib/arch/
  final tempDir = Directory(
    '$projectRoot/build_tool/.aria2_extract_$platform-$arch',
  );
  try {
    tempDir.createSync(recursive: true);
    final extractResult = Process.runSync('tar', [
      '-xzf',
      tarGzFile.path,
      '-C',
      tempDir.path,
    ]);
    if (extractResult.exitCode != 0) {
      stderr.writeln('Failed to extract: ${extractResult.stderr}');
      exit(1);
    }
    final srcAria2 = Directory('${tempDir.path}/aria2lib');
    if (!srcAria2.existsSync()) {
      stderr.writeln('Expected aria2lib/ inside tarball.');
      exit(1);
    }
    if (extractDir.existsSync()) {
      extractDir.deleteSync(recursive: true);
    }
    srcAria2.renameSync(extractDir.path);
  } finally {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  }
  print('Extraction completed.');

  // 清理下载的压缩包
  tarGzFile.deleteSync();
  print('Cleaned up temporary file.');
}
