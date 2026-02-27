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
  s.source_files     = 'Classes/**/*.{h,m,mm,swift,cpp}'
  s.preserve_paths   = 'aria2lib/**/*'
  s.vendored_libraries = 'aria2lib/current/Release/lib/libaria2_c_api.dylib'

  # If your plugin requires a privacy manifest, for example if it collects user
  # data, update the PrivacyInfo.xcprivacy file to describe your plugin's
  # privacy impact, and then uncomment this line. For more information,
  # see https://developer.apple.com/documentation/bundleresources/privacy_manifest_files
  # s.resource_bundles = {'flutter_aria2_privacy' => ['Resources/PrivacyInfo.xcprivacy']}

  s.dependency 'FlutterMacOS'

  s.platform = :osx, '10.11'
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'CLANG_CXX_LANGUAGE_STANDARD' => 'c++17',
    'HEADER_SEARCH_PATHS' => '$(inherited) "${PODS_TARGET_SRCROOT}/../common" "${PODS_TARGET_SRCROOT}/aria2lib/current/Debug/include" "${PODS_TARGET_SRCROOT}/aria2lib/current/Release/include"',
    'LIBRARY_SEARCH_PATHS' => '$(inherited) "${PODS_TARGET_SRCROOT}/aria2lib/current/Debug/lib" "${PODS_TARGET_SRCROOT}/aria2lib/current/Release/lib"',
    'OTHER_LDFLAGS' => '$(inherited) -laria2_c_api',
  }
  s.swift_version = '5.0'

  s.script_phases = [
    {
      :name => 'Sync aria2 deps',
      :execution_position => :before_compile,
      :shell_path => '/bin/sh',
      :script => <<-SCRIPT
set -euo pipefail

ARCH_NAME="${ARCHS%% *}"
if [ "${ARCH_NAME}" = "arm64" ]; then
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

"${DART_BIN}" run "${PODS_TARGET_SRCROOT}/../build_tool/sync_deps.dart" macos "${ARCH_ARG}" 0.1.2

cd "${PODS_TARGET_SRCROOT}"
rm -f aria2lib/current
ln -s "${ARCH_ARG}" aria2lib/current
      SCRIPT
    },
  ]
end
