import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;

final bool _ansi = stdout.supportsAnsiEscapes;

String _wrap(String code, String s) => _ansi ? '\x1B[${code}m$s\x1B[0m' : s;
String bold(String s) => _wrap('1', s);
String dim(String s) => _wrap('2', s);
String red(String s) => _wrap('31', s);
String green(String s) => _wrap('32', s);
String yellow(String s) => _wrap('33', s);
String cyan(String s) => _wrap('36', s);

/// Worker count for background isolates.
final int cpuCount = Platform.numberOfProcessors.clamp(2, 12);

String home() =>
    Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'] ?? '.';

String? env(String name) {
  final v = Platform.environment[name];
  return (v == null || v.isEmpty) ? null : v;
}

/// Comparable form of a path (case-insensitive on Windows).
String pathKey(String path) {
  final n = p.normalize(p.absolute(path));
  return Platform.isWindows ? n.toLowerCase() : n;
}

/// Formats [bytes] as a short size such as `4.22 GB`.
String formatBytes(int bytes) {
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var value = bytes.toDouble();
  var i = 0;
  while (value >= 1024 && i < units.length - 1) {
    value /= 1024;
    i++;
  }
  return '${value.toStringAsFixed(i == 0 ? 0 : (i >= 3 ? 2 : 1))} ${units[i]}';
}

String formatAge(DateTime? t) {
  if (t == null) return '-';
  final d = DateTime.now().difference(t);
  if (d.inDays >= 365) return '${d.inDays ~/ 365}y ago';
  if (d.inDays >= 30) return '${d.inDays ~/ 30}mo ago';
  if (d.inDays >= 1) return '${d.inDays}d ago';
  if (d.inHours >= 1) return '${d.inHours}h ago';
  if (d.inMinutes >= 1) return '${d.inMinutes}m ago';
  return 'just now';
}

/// Parses "14", "14d", "2w", "3mo", "1y" into days. Null if not understood.
int? parseDays(String input) {
  final m = RegExp(
    r'^\s*(\d+)\s*(d|w|mo|m|y)?\s*$',
  ).firstMatch(input.toLowerCase());
  if (m == null) return null;
  final n = int.parse(m.group(1)!);
  return switch (m.group(2)) {
    'w' => n * 7,
    'mo' || 'm' => n * 30,
    'y' => n * 365,
    _ => n,
  };
}

/// Total size of all files under [path], not following links. Unreadable
/// folders are skipped.
int dirSizeSync(String path) {
  final type = FileSystemEntity.typeSync(path, followLinks: false);
  if (type == FileSystemEntityType.file) {
    try {
      return File(path).lengthSync();
    } catch (_) {
      return 0;
    }
  }
  if (type != FileSystemEntityType.directory) return 0;
  var total = 0;
  final stack = [path];
  while (stack.isNotEmpty) {
    final dir = stack.removeLast();
    List<FileSystemEntity> children;
    try {
      children = Directory(dir).listSync(followLinks: false);
    } catch (_) {
      continue;
    }
    for (final c in children) {
      if (c is File) {
        try {
          total += c.statSync().size;
        } catch (_) {}
      } else if (c is Directory) {
        stack.add(c.path);
      }
    }
  }
  return total;
}

/// Size of [path], measured in a background isolate.
Future<int> dirSize(String path) => Isolate.run(() => dirSizeSync(path));

/// Sizes of each of [paths], measured in parallel isolates.
Future<List<int>> sizesOf(List<String> paths) =>
    pooled(paths, dirSize, concurrency: cpuCount);

/// Combined size of many (usually small) paths, in one isolate.
Future<int> totalSizeOf(List<String> paths) =>
    Isolate.run(() => paths.fold<int>(0, (s, x) => s + dirSizeSync(x)));

/// Runs [task] over [items] with at most [concurrency] in flight.
Future<List<R>> pooled<T, R>(
  List<T> items,
  Future<R> Function(T) task, {
  int concurrency = 6,
}) async {
  final results = List<R?>.filled(items.length, null);
  var next = 0;
  Future<void> worker() async {
    while (next < items.length) {
      final i = next++;
      results[i] = await task(items[i]);
    }
  }

  await Future.wait(List.generate(concurrency, (_) => worker()));
  return results.cast<R>();
}

/// Deletes a file or directory tree, tolerating read-only files on Windows.
Future<bool> deletePath(String path) async {
  final type = await FileSystemEntity.type(path, followLinks: false);
  if (type == FileSystemEntityType.notFound) return true;
  try {
    if (type == FileSystemEntityType.directory) {
      await Directory(path).delete(recursive: true);
    } else {
      await File(path).delete();
    }
    return true;
  } catch (_) {
    if (Platform.isWindows && type == FileSystemEntityType.directory) {
      // Clear read-only attributes (common in .gradle / git packs) and retry.
      await Process.run('attrib', [
        '-R',
        p.join(path, '*'),
        '/S',
        '/D',
      ], runInShell: true);
      await Process.run('cmd', ['/c', 'rmdir', '/s', '/q', path]);
    }
    return !await FileSystemEntity.isDirectory(path) &&
        !await FileSystemEntity.isFile(path);
  }
}

/// Moves [paths] to the Recycle Bin / Trash. Returns the paths that failed.
Future<List<String>> trashPaths(List<String> paths) async {
  final existing = paths
      .where(
        (x) =>
            FileSystemEntity.typeSync(x, followLinks: false) !=
            FileSystemEntityType.notFound,
      )
      .toList();
  if (existing.isEmpty) return [];

  if (Platform.isWindows) {
    final tmp = await Directory.systemTemp.createTemp('buildremove');
    try {
      final list = File(p.join(tmp.path, 'paths.txt'));
      await list.writeAsString(existing.join('\r\n'));
      final script = File(p.join(tmp.path, 'trash.ps1'));
      await script.writeAsString(r'''
param([string]$ListFile)
Add-Type -AssemblyName Microsoft.VisualBasic
foreach ($x in Get-Content -LiteralPath $ListFile -Encoding UTF8) {
  try {
    if (Test-Path -LiteralPath $x -PathType Container) {
      [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory($x, 'OnlyErrorDialogs', 'SendToRecycleBin')
    } elseif (Test-Path -LiteralPath $x) {
      [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($x, 'OnlyErrorDialogs', 'SendToRecycleBin')
    }
  } catch { Write-Output $x }
}
''');
      final r = await Process.run('powershell', [
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        script.path,
        list.path,
      ]);
      return (r.stdout as String)
          .split(RegExp(r'\r?\n'))
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toList();
    } finally {
      await tmp.delete(recursive: true);
    }
  }

  final failed = <String>[];
  for (final x in existing) {
    try {
      if (Platform.isMacOS) {
        final trash = p.join(home(), '.Trash');
        var target = p.join(trash, p.basename(x));
        if (FileSystemEntity.typeSync(target) !=
            FileSystemEntityType.notFound) {
          target = '$target ${DateTime.now().millisecondsSinceEpoch}';
        }
        await (FileSystemEntity.isDirectorySync(x) ? Directory(x) : File(x))
            .rename(target);
      } else {
        final r = await Process.run('gio', ['trash', x]);
        if (r.exitCode != 0) failed.add(x);
      }
    } catch (_) {
      failed.add(x);
    }
  }
  return failed;
}

/// Free and total bytes per Windows drive root ("C:\"), via PowerShell.
Future<Map<String, (int, int)>> windowsDriveSpace() async {
  final space = <String, (int, int)>{};
  try {
    final r = await Process.run('powershell', [
      '-NoProfile',
      '-Command',
      r'Get-PSDrive -PSProvider FileSystem | ForEach-Object { "$($_.Root)|$($_.Free)|$($_.Used)" }',
    ]);
    for (final line in (r.stdout as String).split(RegExp(r'\r?\n'))) {
      final parts = line.trim().split('|');
      if (parts.length != 3) continue;
      final free = int.tryParse(parts[1]);
      final used = int.tryParse(parts[2]);
      if (free != null && used != null) {
        space[parts[0].toUpperCase()] = (free, free + used);
      }
    }
  } catch (_) {}
  return space;
}

/// Free bytes on the volumes holding [paths], keyed by volume root.
Future<Map<String, int>> volumeFree(Iterable<String> paths) async {
  final result = <String, int>{};
  if (Platform.isWindows) {
    final drives = await windowsDriveSpace();
    for (final x in paths) {
      final root = p.rootPrefix(p.absolute(x)).toUpperCase();
      final s = drives[root];
      if (s != null) result[root] = s.$1;
    }
    return result;
  }
  for (final x in paths) {
    try {
      final r = await Process.run('df', ['-Pk', x]);
      final last = (r.stdout as String).trim().split('\n').last;
      final cols = last.split(RegExp(r'\s+'));
      result[cols.last] = int.parse(cols[3]) * 1024;
    } catch (_) {}
  }
  return result;
}

/// Prints free space per volume before and after a cleanup.
void printFreeChange(Map<String, int> before, Map<String, int> after) {
  if (before.isEmpty) return;
  stdout.writeln(bold('\nFree space'));
  for (final vol in before.keys) {
    final b = before[vol]!;
    final a = after[vol] ?? b;
    final diff = a - b;
    final change = diff >= 0
        ? green('+${formatBytes(diff)}')
        : yellow('-${formatBytes(-diff)}');
    stdout.writeln(
      '  ${vol.padRight(6)} ${formatBytes(b)} -> ${bold(formatBytes(a))}  ($change)',
    );
  }
}

/// Finds every executable named [name] on PATH.
Future<List<String>> which(String name) async {
  try {
    final r = Platform.isWindows
        ? await Process.run('where', [name], runInShell: true)
        : await Process.run('which', ['-a', name]);
    if (r.exitCode != 0) return [];
    return (r.stdout as String)
        .split(RegExp(r'\r?\n'))
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toSet()
        .toList();
  } catch (_) {
    return [];
  }
}

/// Shortens [s] to [width] characters.
String fit(String s, int width) => s.length <= width
    ? s
    : '${s.substring(0, (width - 1).clamp(0, s.length))}…';

/// Prints [message] on the current line, overwriting it (for progress).
void status(String message) {
  if (!stdout.hasTerminal) return;
  final width = stdout.terminalColumns - 1;
  final text = message.length > width
      ? '…${message.substring(message.length - width + 1)}'
      : message;
  stdout.write('\r${text.padRight(width)}\r');
}

void clearStatus() {
  if (!stdout.hasTerminal) return;
  stdout.write('\r${' ' * (stdout.terminalColumns - 1)}\r');
}
