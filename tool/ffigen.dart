// Regenerates lib/src/native/terra_bindings.g.dart from
// native/include/terra_core.h.
//
//   fvm dart run tool/ffigen.dart
//
// Needs libclang: set LIBCLANG_PATH, or install LLVM (Homebrew `llvm`,
// apt `libclang-dev`).

import 'dart:io';

import 'package:ffigen/ffigen.dart';

const _assetId = 'package:terra/terra_core';

Uri? _findLibclang() {
  final env = Platform.environment['LIBCLANG_PATH'];
  if (env != null && env.isNotEmpty) return Uri.file(env);
  final candidates = <String>[
    for (final v in ['', '@21', '@20', '@19']) ...[
      '/opt/homebrew/opt/llvm$v/lib/libclang.dylib',
      '/usr/local/opt/llvm$v/lib/libclang.dylib',
    ],
    '/Library/Developer/CommandLineTools/usr/lib/libclang.dylib',
    for (final v in ['21', '20', '19', '18']) '/usr/lib/llvm-$v/lib/libclang.so',
    r'C:\Program Files\LLVM\bin\libclang.dll',
  ];
  for (final c in candidates) {
    if (File(c).existsSync()) return Uri.file(c);
  }
  return null;
}

Future<void> main() async {
  final root = Platform.script.resolve('../');
  final generator = FfiGenerator(
    output: Output(
      dart: DartOutput(path: root.resolve('lib/src/native/terra_bindings.g.dart')),
      style: const NativeExternalBindings(assetId: _assetId),
      preamble: '''
// Copyright (C) 2026 Terra FM contributors. GPL-3.0-or-later.
// Generated from native/include/terra_core.h by tool/ffigen.dart.
''',
    ),
    input: Input(
      entryPoints: [root.resolve('native/include/terra_core.h')],
      include: (header) => header.path.endsWith('terra_core.h'),
    ),
    visitors: [
      Visitor(
        func: (node) => node.isIncluded = node.name.startsWith('terra_'),
        struct: (node) => node.isIncluded = node.name.startsWith('terra_'),
        union: (node) => node.isIncluded = true,
        enumClass: (node) {
          node.isIncluded = node.name.startsWith('terra_');
          node.style = EnumStyle.intConstants;
        },
        macroConstant: (node) => node.isIncluded = node.name.startsWith('TERRA_') && node.name != 'TERRA_API',
        typealias: (node) => node.isIncluded = node.name.startsWith('terra_') ? .always : .ifUsed,
      ),
    ],
  );
  await generator.generate(libclangDylib: _findLibclang());
}
