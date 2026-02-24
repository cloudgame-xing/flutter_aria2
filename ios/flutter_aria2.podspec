#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint flutter_aria2.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'flutter_aria2'
  s.version          = '0.0.1'
  s.summary          = 'A new Flutter plugin project.'
  s.description      = <<-DESC
A new Flutter plugin project.
                       DESC
  s.homepage         = 'http://example.com'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Your Company' => 'email@example.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*.{h,m,mm,swift}'
  s.public_header_files = 'Classes/**/*.h'
  s.preserve_paths   = 'aria2lib/**/*'
  s.vendored_libraries = 'aria2lib/Release/lib/libaria2_c_api.dylib'
  s.dependency 'Flutter'
  s.platform = :ios, '13.0'

  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386',
    'CLANG_CXX_LANGUAGE_STANDARD' => 'c++17',
    'HEADER_SEARCH_PATHS' => '$(inherited) "${PODS_TARGET_SRCROOT}/aria2lib/Debug/include" "${PODS_TARGET_SRCROOT}/aria2lib/Release/include"',
    'LIBRARY_SEARCH_PATHS' => '$(inherited) "${PODS_TARGET_SRCROOT}/aria2lib/Debug/lib" "${PODS_TARGET_SRCROOT}/aria2lib/Release/lib"',
    'OTHER_LDFLAGS' => '$(inherited) -laria2_c_api',
    'LD_RUNPATH_SEARCH_PATHS' => '$(inherited) @loader_path @loader_path/Frameworks @executable_path/Frameworks',
  }
  s.swift_version = '5.0'

  # If your plugin requires a privacy manifest, for example if it uses any
  # required reason APIs, update the PrivacyInfo.xcprivacy file to describe your
  # plugin's privacy impact, and then uncomment this line. For more information,
  # see https://developer.apple.com/documentation/bundleresources/privacy_manifest_files
  # s.resource_bundles = {'flutter_aria2_privacy' => ['Resources/PrivacyInfo.xcprivacy']}

  s.script_phases = [
    {
      :name => 'Sync aria2 deps',
      :execution_position => :before_compile,
      :shell_path => '/bin/sh',
      :script => <<-SCRIPT
set -euo pipefail

if [ "${PLATFORM_NAME:-iphoneos}" = "iphoneos" ]; then
  ARCH_ARG="arm64"
else
  ARCH_ARG="x64"
fi

if command -v dart >/dev/null 2>&1; then
  DART_BIN="dart"
elif [ -n "${FLUTTER_ROOT:-}" ] && [ -x "${FLUTTER_ROOT}/bin/dart" ]; then
  DART_BIN="${FLUTTER_ROOT}/bin/dart"
else
  echo "error: dart executable not found."
  exit 1
fi

"${DART_BIN}" run "${PODS_TARGET_SRCROOT}/../build_tool/sync_deps.dart" ios "${ARCH_ARG}" 0.1.1
      SCRIPT
    },
    {
      :name => 'Embed aria2 dylib',
      :execution_position => :after_compile,
      :shell_path => '/bin/sh',
      :script => <<-SCRIPT
set -euo pipefail

if [ "${CONFIGURATION}" = "Debug" ]; then
  LIB_SRC="${PODS_TARGET_SRCROOT}/aria2lib/Debug/lib/libaria2_c_api.dylib"
else
  LIB_SRC="${PODS_TARGET_SRCROOT}/aria2lib/Release/lib/libaria2_c_api.dylib"
fi

if [ ! -f "${LIB_SRC}" ]; then
  echo "error: missing aria2 dylib at ${LIB_SRC}"
  exit 1
fi

FRAMEWORK_DIR="${TARGET_BUILD_DIR}/${FULL_PRODUCT_NAME}"
DEST_LIB="${FRAMEWORK_DIR}/libaria2_c_api.dylib"
mkdir -p "${FRAMEWORK_DIR}"
cp -f "${LIB_SRC}" "${DEST_LIB}"

if [ "${CODE_SIGNING_ALLOWED:-NO}" = "YES" ] && [ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]; then
  /usr/bin/codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY}" --timestamp=none "${DEST_LIB}"
fi
      SCRIPT
    },
  ]
end
