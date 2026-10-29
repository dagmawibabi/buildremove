import 'dart:io';

import 'package:args/args.dart';
import 'package:buildremove/src/app.dart';
import 'package:buildremove/src/util.dart';

const _usage = '''
buildremove: find and clean Flutter/Dart build artifacts.

Usage:
  buildremove                  Interactive menu
  buildremove scan [paths...]  Scan paths (or pick drives/folders) and clean
  buildremove info             Flutter SDKs, FVM, Android SDK, Gradle, caches, with usage
  buildremove ignored          Stop ignoring projects
  buildremove config           Show saved settings

Options:''';

Future<void> main(List<String> arguments) async {
  final parser = ArgParser()
    ..addFlag(
      'dry-run',
      abbr: 'n',
      negatable: false,
      help: 'Show what would be freed, delete nothing.',
    )
    ..addOption(
      'older-than',
      abbr: 'o',
      valueHelp: 'age',
      help:
          'scan: only show projects not built for this long (e.g. 14d, 2w, 3mo).',
    )
    ..addFlag(
      'fresh',
      abbr: 'f',
      negatable: false,
      help: 'scan: ignore the cached last scan.',
    )
    ..addFlag(
      'yes',
      abbr: 'y',
      negatable: false,
      help:
          'scan: clean every project found with flutter clean, without asking.',
    )
    ..addFlag('help', abbr: 'h', negatable: false, help: 'Show this help.');

  ArgResults args;
  try {
    args = parser.parse(arguments);
  } on FormatException catch (e) {
    stderr.writeln('${e.message}\n\n$_usage\n${parser.usage}');
    exit(64);
  }
  if (args.flag('help')) {
    stdout.writeln('$_usage\n${parser.usage}');
    return;
  }

  int? olderThan;
  if (args.option('older-than') case final value?) {
    olderThan = parseDays(value);
    if (olderThan == null) {
      stderr.writeln(
        'Could not read --older-than "$value". Use e.g. 14d, 2w or 3mo.',
      );
      exit(64);
    }
  }

  final dryRun = args.flag('dry-run');
  final rest = args.rest;
  switch (rest.isEmpty ? null : rest.first) {
    case null:
      await menu(dryRun: dryRun);
    case 'scan':
      final paths = rest.skip(1).toList();
      final missing = paths.where((p) => !Directory(p).existsSync()).toList();
      if (missing.isNotEmpty) {
        stderr.writeln('Not found: ${missing.join(', ')}');
        exit(66);
      }
      if (args.flag('yes') && paths.isEmpty) {
        stderr.writeln(
          '--yes needs explicit paths, e.g. buildremove scan D:\\Projects --yes',
        );
        exit(64);
      }
      await scanFlow(
        paths,
        dryRun: dryRun,
        yes: args.flag('yes'),
        fresh: args.flag('fresh'),
        olderThanDays: olderThan,
      );
    case 'info':
      await infoFlow(dryRun: dryRun, interactive: stdin.hasTerminal);
    case 'ignored':
      await ignoredFlow();
    case 'config':
      configFlow();
    default:
      stderr.writeln(
        'Unknown command "${rest.first}".\n\n$_usage\n${parser.usage}',
      );
      exit(64);
  }
}
