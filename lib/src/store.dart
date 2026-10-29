import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'scanner.dart';
import 'util.dart';

class CachedScan {
  CachedScan(this.time, this.roots, this.projects);
  final DateTime time;
  final List<String> roots;
  final List<Project> projects;
}

/// Settings and the last scan, kept in ~/.buildremove.
class Store {
  Store._(this._config, this._scan);

  static final String dir = p.join(home(), '.buildremove');
  static String get configPath => p.join(dir, 'config.json');
  static String get scanPath => p.join(dir, 'last_scan.json');

  final Map<String, dynamic> _config;
  Map<String, dynamic>? _scan;

  static Map<String, dynamic>? _read(String path) {
    try {
      return jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  static Store load() => Store._(_read(configPath) ?? {}, _read(scanPath));

  void save() {
    try {
      Directory(dir).createSync(recursive: true);
      const encoder = JsonEncoder.withIndent('  ');
      File(configPath).writeAsStringSync(encoder.convert(_config));
      if (_scan != null) File(scanPath).writeAsStringSync(jsonEncode(_scan));
    } catch (e) {
      stderr.writeln(yellow('Could not save settings to $dir: $e'));
    }
  }

  List<String> _list(String key) =>
      ((_config[key] as List?) ?? const []).cast<String>();

  /// Folders chosen in the last scan.
  List<String> get lastRoots => _list('lastRoots');
  set lastRoots(List<String> roots) => _config['lastRoots'] = roots;

  /// Projects hidden from scan results.
  List<String> get ignored => _list('ignored');
  bool isIgnored(String root) =>
      ignored.any((i) => pathKey(i) == pathKey(root));
  void ignore(Iterable<String> roots) =>
      _config['ignored'] = {...ignored, ...roots}.toList()..sort();
  void unignore(Iterable<String> roots) {
    final keys = roots.map(pathKey).toSet();
    _config['ignored'] = ignored
        .where((i) => !keys.contains(pathKey(i)))
        .toList();
  }

  /// Hide projects built in the last N days.
  int? get olderThanDays => _config['olderThanDays'] as int?;
  set olderThanDays(int? days) => _config['olderThanDays'] = days;

  /// Every project root seen in any scan; used to tell which SDKs and
  /// caches are still in use.
  List<String> get knownProjects => _list('knownProjects');
  void addKnownProjects(Iterable<String> roots) {
    final byKey = {for (final r in knownProjects) pathKey(r): r};
    for (final r in roots) {
      byKey.putIfAbsent(pathKey(r), () => r);
    }
    _config['knownProjects'] =
        byKey.values
            .where((r) => File(p.join(r, 'pubspec.yaml')).existsSync())
            .toList()
          ..sort();
  }

  /// The last measured scan, if it covered exactly [roots].
  CachedScan? cachedScan(List<String> roots) {
    final s = _scan;
    if (s == null) return null;
    try {
      final cachedRoots = (s['roots'] as List).cast<String>();
      if (cachedRoots
              .map(pathKey)
              .toSet()
              .difference(roots.map(pathKey).toSet())
              .isNotEmpty ||
          roots
              .map(pathKey)
              .toSet()
              .difference(cachedRoots.map(pathKey).toSet())
              .isNotEmpty) {
        return null;
      }
      return CachedScan(DateTime.parse(s['time'] as String), cachedRoots, [
        for (final j in s['projects'] as List) Project.fromJson(j as Map),
      ]);
    } catch (_) {
      return null;
    }
  }

  void saveScan(List<String> roots, List<Project> projects) => _scan = {
    'time': DateTime.now().toIso8601String(),
    'roots': roots,
    'projects': [for (final pr in projects) pr.toJson()],
  };

  /// Drops cleaned projects from the cached scan.
  void forgetFromScan(Iterable<String> roots) {
    final s = _scan;
    if (s == null) return;
    final keys = roots.map(pathKey).toSet();
    s['projects'] = (s['projects'] as List)
        .where((j) => !keys.contains(pathKey((j as Map)['root'] as String)))
        .toList();
  }

  String describe() {
    const encoder = JsonEncoder.withIndent('  ');
    return encoder.convert({
      'lastRoots': lastRoots,
      'ignored': ignored,
      'olderThanDays': olderThanDays,
      'knownProjects': '${knownProjects.length} projects',
      'lastScan': _scan?['time'],
    });
  }
}
