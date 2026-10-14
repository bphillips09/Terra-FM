// Builds native/ (terra_core + nrsc5, FAAD2, librtlsdr, libusb, miniaudio)
// with CMake for the target the Flutter tool asks for, and bundles the shared
// library as the `package:terra/terra_core` code asset.
//
// Optional overrides (pubspec.yaml):
//
//   hooks:
//     user_defines:
//       terra:
//         cmake: /path/to/cmake
//         ninja: /path/to/ninja
//         mingw_bin: C:/msys64/ucrt64/bin   # Windows: MinGW-w64 gcc/g++

import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';

const _assetName = 'terra_core';

void main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) return;
    final code = input.config.code;
    final root = input.packageRoot;
    final nativeDir = root.resolve('native/');
    final thirdParty = root.resolve('third_party/');

    await _ensureThirdParty(root, thirdParty);

    final buildDir = input.outputDirectory.resolve('cmake/');
    final tools = _Tools.find(input);
    final configureArgs = <String>[
      '-S', nativeDir.toFilePath(),
      '-B', buildDir.toFilePath(),
      '-DCMAKE_BUILD_TYPE=Release',
      '-DTERRA_THIRD_PARTY_DIR=${thirdParty.toFilePath()}',
      ...tools.generatorArgs(code.targetOS),
      ..._targetArgs(code, tools),
    ];

    await _run(tools.cmake, configureArgs, environment: tools.environment);
    await _run(tools.cmake, [
      '--build', buildDir.toFilePath(),
      '--target', 'terra_core',
      '--parallel', '${Platform.numberOfProcessors}',
    ], environment: tools.environment);

    final library = buildDir.resolve(switch (code.targetOS) {
      OS.windows => 'terra_core.dll',
      OS.macOS || OS.iOS => 'libterra_core.dylib',
      _ => 'libterra_core.so',
    });
    final file = File.fromUri(library);
    if (!file.existsSync()) {
      throw BuildError(message: 'CMake finished but ${library.toFilePath()} is missing');
    }

    output.assets.code.add(CodeAsset(
      package: input.packageName,
      name: _assetName,
      linkMode: DynamicLoadingBundled(),
      file: library,
    ));
    output.dependencies.addAll([
      ..._filesUnder(Directory.fromUri(nativeDir), exclude: 'build'),
      ..._filesUnder(Directory.fromUri(root.resolve('tooling/patches/')), exclude: 'build'),
      root.resolve('tooling/fetch_third_party.sh'),
      for (final dep in _thirdPartyDeps) thirdParty.resolve('$dep/.terra-stamp'),
    ]);
  });
}

const _thirdPartyDeps = ['nrsc5', 'faad2', 'libusb', 'rtl-sdr', 'miniaudio'];

/// The fetch script is a no-op when every stamp matches its pin and patches.
Future<void> _ensureThirdParty(Uri root, Uri thirdParty) async {
  final script = root.resolve('tooling/fetch_third_party.sh').toFilePath();
  if (!Platform.isWindows) {
    await _run('bash', [script]);
    return;
  }
  final missing =
      _thirdPartyDeps.where((d) => !File.fromUri(thirdParty.resolve('$d/.terra-stamp')).existsSync()).toList();
  if (missing.isNotEmpty) {
    throw BuildError(
      message: 'Missing third_party sources (${missing.join(', ')}). '
          'Run `bash tooling/fetch_third_party.sh` from Git Bash or MSYS2.',
    );
  }
}

List<String> _targetArgs(CodeConfig code, _Tools tools) {
  switch (code.targetOS) {
    case OS.android:
      final compiler = code.cCompiler?.compiler;
      if (compiler == null) throw BuildError(message: 'No Android NDK compiler provided');
      // <ndk>/toolchains/llvm/prebuilt/<host>/bin/clang
      final ndk = File.fromUri(compiler).parent.parent.parent.parent.parent.parent;
      final toolchain = File('${ndk.path}/build/cmake/android.toolchain.cmake');
      if (!toolchain.existsSync()) {
        throw BuildError(message: 'Cannot find android.toolchain.cmake under ${ndk.path}');
      }
      final abi = switch (code.targetArchitecture) {
        Architecture.arm64 => 'arm64-v8a',
        Architecture.arm => 'armeabi-v7a',
        Architecture.x64 => 'x86_64',
        Architecture.ia32 => 'x86',
        final a => throw BuildError(message: 'Unsupported Android architecture $a'),
      };
      return [
        '-DCMAKE_TOOLCHAIN_FILE=${toolchain.path}',
        '-DANDROID_ABI=$abi',
        '-DANDROID_PLATFORM=android-${code.android.targetNdkApi}',
        '-DANDROID_STL=c++_static',
      ];
    case OS.macOS:
      final arch = switch (code.targetArchitecture) {
        Architecture.arm64 => 'arm64',
        Architecture.x64 => 'x86_64',
        final a => throw BuildError(message: 'Unsupported macOS architecture $a'),
      };
      return [
        '-DCMAKE_OSX_ARCHITECTURES=$arch',
        '-DCMAKE_OSX_DEPLOYMENT_TARGET=${code.macOS.targetVersion}',
        ..._compilerArgs(code.cCompiler),
      ];
    case OS.linux:
      return _compilerArgs(code.cCompiler);
    case OS.windows:
      // nrsc5 needs C99 complex types, so MSVC (what Flutter provides) is out.
      final bin = tools.mingwBin;
      if (bin == null) {
        throw BuildError(
          message: 'Building terra_core on Windows needs MinGW-w64 (gcc/g++), e.g. MSYS2 UCRT64. '
              'Install it or set hooks.user_defines.terra.mingw_bin in pubspec.yaml.',
        );
      }
      return [
        '-DCMAKE_C_COMPILER=${bin.resolve('gcc.exe').toFilePath()}',
        '-DCMAKE_CXX_COMPILER=${bin.resolve('g++.exe').toFilePath()}',
      ];
    default:
      throw BuildError(message: 'terra_core does not support ${code.targetOS} yet');
  }
}

List<String> _compilerArgs(CCompilerConfig? config) {
  if (config == null) return const [];
  final cc = File.fromUri(config.compiler);
  final name = cc.uri.pathSegments.last;
  final cxxName = name.contains('clang') ? name.replaceFirst('clang', 'clang++') : name.replaceFirst('gcc', 'g++');
  final cxx = File('${cc.parent.path}/$cxxName');
  return [
    '-DCMAKE_C_COMPILER=${cc.path}',
    if (cxx.existsSync()) '-DCMAKE_CXX_COMPILER=${cxx.path}',
  ];
}

Iterable<Uri> _filesUnder(Directory dir, {required String exclude}) sync* {
  for (final entity in dir.listSync(recursive: true, followLinks: false)) {
    if (entity is! File) continue;
    final relative = entity.path.substring(dir.path.length);
    if (relative.split(RegExp(r'[/\\]')).contains(exclude)) continue;
    yield entity.uri;
  }
}

Future<void> _run(String executable, List<String> args, {Map<String, String>? environment}) async {
  final result = await Process.run(executable, args, environment: environment, runInShell: Platform.isWindows);
  if (result.exitCode != 0) {
    throw BuildError(
      message: '`$executable ${args.join(' ')}` failed (${result.exitCode}):\n'
          '${result.stdout}\n${result.stderr}',
    );
  }
}

class _Tools {
  _Tools(this.cmake, this.ninja, this.mingwBin, this.environment);

  final String cmake;
  final String? ninja;
  final Uri? mingwBin;
  final Map<String, String>? environment;

  List<String> generatorArgs(OS target) {
    if (ninja != null) return ['-G', 'Ninja', '-DCMAKE_MAKE_PROGRAM=$ninja'];
    if (Platform.isWindows) return ['-G', 'MinGW Makefiles'];
    return ['-G', 'Unix Makefiles'];
  }

  static _Tools find(BuildInput input) {
    final defines = input.userDefines;
    final cmake = defines.path('cmake')?.toFilePath() ??
        _which('cmake', _cmakeFallbacks()) ??
        (throw BuildError(message: 'CMake not found. Install it or set hooks.user_defines.terra.cmake.'));
    final ninja = defines.path('ninja')?.toFilePath() ??
        _which('ninja', [
          // Ninja ships next to the Android SDK's CMake.
          for (final c in _cmakeFallbacks()) File(c).parent.uri.resolve('ninja').toFilePath(),
        ]);

    Uri? mingw;
    Map<String, String>? env;
    if (Platform.isWindows) {
      mingw = defines.path('mingw_bin') ??
          [r'C:\msys64\ucrt64\bin', r'C:\msys64\mingw64\bin', r'C:\msys64\clang64\bin']
              .map(Directory.new)
              .where((d) => File('${d.path}\\gcc.exe').existsSync())
              .map((d) => d.uri)
              .firstOrNull;
      if (mingw != null) {
        // MinGW's make/ninja and the compilers need their DLLs on PATH.
        env = {'PATH': '${mingw.toFilePath()};${Platform.environment['PATH'] ?? ''}'};
      }
    }
    return _Tools(cmake, ninja, mingw, env);
  }

  static List<String> _cmakeFallbacks() {
    final home = Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'] ?? '';
    final sdks = <String>[
      ?Platform.environment['ANDROID_HOME'],
      ?Platform.environment['ANDROID_SDK_ROOT'],
      '$home/Library/Android/sdk',
      '$home/Android/Sdk',
      '$home/AppData/Local/Android/Sdk',
    ];
    final found = <String>[];
    for (final sdk in sdks) {
      final dir = Directory('$sdk/cmake');
      if (!dir.existsSync()) continue;
      final versions = dir.listSync().whereType<Directory>().toList()
        ..sort((a, b) => b.path.compareTo(a.path));
      for (final v in versions) {
        found.add('${v.path}/bin/cmake${Platform.isWindows ? '.exe' : ''}');
      }
    }
    return [
      '/opt/homebrew/bin/cmake',
      '/usr/local/bin/cmake',
      '/Applications/CMake.app/Contents/bin/cmake',
      '/usr/bin/cmake',
      r'C:\Program Files\CMake\bin\cmake.exe',
      ...found,
    ];
  }

  static String? _which(String name, List<String> fallbacks) {
    final exe = Platform.isWindows ? '$name.exe' : name;
    final pathDirs = (Platform.environment['PATH'] ?? '').split(Platform.isWindows ? ';' : ':');
    for (final dir in pathDirs) {
      if (dir.isEmpty) continue;
      final f = File('$dir${Platform.pathSeparator}$exe');
      if (f.existsSync()) return f.path;
    }
    for (final f in fallbacks) {
      if (File(f).existsSync()) return f;
    }
    return null;
  }
}
