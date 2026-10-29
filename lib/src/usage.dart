import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'scanner.dart';

/// Which SDK versions and cached packages the known projects reference.
class Usage {
  /// Creates an empty report for [projectCount] projects.
  Usage(this.projectCount);

  /// How many projects were checked.
  final int projectCount;

  /// NDK version -> names of projects that use it.
  final ndk = <String, Set<String>>{};

  /// Gradle version -> names of projects whose wrapper uses it.
  final gradle = <String, Set<String>>{};

  /// FVM Flutter version -> names of projects pinned to it.
  final fvm = <String, Set<String>>{};

  /// Pub cache package folder names ("name-1.2.3") still referenced.
  final pubKeep = <String>{};

  /// Whether any projects were checked, so "unused" means something.
  bool get known => projectCount > 0;

  /// "used by 2: app, other" or "not used by any known project".
  String tag(Map<String, Set<String>> map, String version) {
    if (!known) return '';
    final users = map[version];
    if (users == null || users.isEmpty) return 'not used by any known project';
    final names = users.toList()..sort();
    final shown = names.take(3).join(', ');
    return 'used by ${names.length}: $shown${names.length > 3 ? ', …' : ''}';
  }

  /// Whether no checked project uses [version] in [map].
  bool unused(Map<String, Set<String>> map, String version) =>
      known && (map[version]?.isEmpty ?? true);
}

/// The FVM-pinned Flutter version of a project, if any.
String? fvmVersionOf(String root) {
  for (final (file, key) in [
    ('.fvmrc', 'flutter'),
    (p.join('.fvm', 'fvm_config.json'), 'flutterSdkVersion'),
  ]) {
    try {
      final data =
          jsonDecode(File(p.join(root, file)).readAsStringSync()) as Map;
      final v = data[key];
      if (v is String && v.isNotEmpty) return v;
    } catch (_) {}
  }
  return null;
}

final _ndkCache = <String, String?>{};

/// The NDK version a Flutter SDK uses for `ndkVersion = flutter.ndkVersion`.
String? flutterDefaultNdk(String? sdkRoot) {
  if (sdkRoot == null) return null;
  return _ndkCache.putIfAbsent(sdkRoot, () {
    final gradle = p.join(
      sdkRoot,
      'packages',
      'flutter_tools',
      'gradle',
      'src',
      'main',
    );
    for (final file in [
      p.join(gradle, 'kotlin', 'FlutterExtension.kt'),
      p.join(gradle, 'groovy', 'flutter.groovy'),
    ]) {
      try {
        final m = RegExp(
          r'ndkVersion\b[^\n=]*=\s*"([\d.]+)"',
        ).firstMatch(File(file).readAsStringSync());
        if (m != null) return m.group(1);
      } catch (_) {}
    }
    return null;
  });
}

/// Reads hosted "name-version" entries from a pubspec.lock.
Set<String> parseLockHosted(String content) {
  final result = <String>{};
  String? name;
  String? source;
  String? version;
  void flush() {
    if (name != null && source == 'hosted' && version != null) {
      result.add('$name-$version');
    }
  }

  final top = RegExp(r'^  ([\w-]+):\s*$');
  final field = RegExp(r'^    (source|version):\s*"?([^"\s]+)"?');
  for (final line in LineSplitter.split(content)) {
    final t = top.firstMatch(line);
    if (t != null) {
      flush();
      name = t.group(1);
      source = null;
      version = null;
      continue;
    }
    final f = field.firstMatch(line);
    if (f != null) {
      if (f.group(1) == 'source') {
        source = f.group(2);
      } else {
        version = f.group(2);
      }
    }
  }
  flush();
  return result;
}

/// Package folder names referenced by a .dart_tool/package_config.json.
Set<String> _packageConfigFolders(String file) {
  try {
    final data = jsonDecode(File(file).readAsStringSync()) as Map;
    return {
      for (final pkg in (data['packages'] as List? ?? const []))
        if ((pkg as Map)['rootUri'] case final String uri
            when uri.contains('/hosted/'))
          Uri.parse(uri).pathSegments.lastWhere((s) => s.isNotEmpty),
    };
  } catch (_) {
    return {};
  }
}

void _addLock(Set<String> keep, String file) {
  try {
    keep.addAll(parseLockHosted(File(file).readAsStringSync()));
  } catch (_) {}
}

/// Project roots FVM itself knows about (FVM 3 keeps a projects.json).
List<String> fvmKnownProjects(List<String> fvmVersionDirs) {
  final roots = <String>[];
  for (final dir in fvmVersionDirs) {
    try {
      final data =
          jsonDecode(
                File(
                  p.join(p.dirname(dir), 'projects.json'),
                ).readAsStringSync(),
              )
              as Map;
      roots.addAll((data['projects'] as List).cast<String>());
    } catch (_) {}
  }
  return roots;
}

/// Checks which NDK, Gradle, FVM and Pub package versions [projectRoots] use.
///
/// [defaultSdk] is the Flutter SDK for projects not pinned with FVM; FVM
/// versions are looked up in [fvmVersionDirs]. Lock files of [sdkRoots] and
/// the global packages and recorded projects of [pubCache] count as used too.
Usage analyzeUsage(
  List<String> projectRoots, {
  String? defaultSdk,
  List<String> fvmVersionDirs = const [],
  List<String> sdkRoots = const [],
  String? pubCache,
}) {
  final usage = Usage(projectRoots.length);
  for (final root in projectRoots) {
    final name = projectName(root);

    final fvmVersion = fvmVersionOf(root);
    String? sdk = defaultSdk;
    if (fvmVersion != null) {
      (usage.fvm[fvmVersion] ??= {}).add(name);
      for (final dir in fvmVersionDirs) {
        final candidate = p.join(dir, fvmVersion);
        if (Directory(candidate).existsSync()) sdk = candidate;
      }
    }

    for (final gradleFile in ['build.gradle.kts', 'build.gradle']) {
      final f = File(p.join(root, 'android', 'app', gradleFile));
      if (!f.existsSync()) continue;
      final text = f.readAsStringSync();
      final explicit = RegExp(
        r'''ndkVersion\s*=?\s*["']([\w.]+)["']''',
      ).firstMatch(text);
      final viaFlutter = RegExp(
        r'ndkVersion\s*=?\s*flutter\.ndkVersion',
      ).hasMatch(text);
      final version =
          explicit?.group(1) ?? (viaFlutter ? flutterDefaultNdk(sdk) : null);
      if (version != null) (usage.ndk[version] ??= {}).add(name);
      break;
    }

    try {
      final props = File(
        p.join(
          root,
          'android',
          'gradle',
          'wrapper',
          'gradle-wrapper.properties',
        ),
      ).readAsStringSync();
      final m = RegExp(r'gradle-([\w.\-]+?)-(all|bin)\.zip').firstMatch(props);
      if (m != null) (usage.gradle[m.group(1)!] ??= {}).add(name);
    } catch (_) {}

    _addLock(usage.pubKeep, p.join(root, 'pubspec.lock'));
    usage.pubKeep.addAll(
      _packageConfigFolders(p.join(root, '.dart_tool', 'package_config.json')),
    );
  }

  // Flutter SDKs and globally activated tools resolve into the pub cache too.
  for (final sdk in {...sdkRoots, ?defaultSdk}) {
    _addLock(usage.pubKeep, p.join(sdk, 'pubspec.lock'));
    try {
      for (final pkg in Directory(
        p.join(sdk, 'packages'),
      ).listSync().whereType<Directory>()) {
        _addLock(usage.pubKeep, p.join(pkg.path, 'pubspec.lock'));
      }
    } catch (_) {}
  }
  if (pubCache != null) {
    try {
      for (final g in Directory(
        p.join(pubCache, 'global_packages'),
      ).listSync().whereType<Directory>()) {
        _addLock(usage.pubKeep, p.join(g.path, 'pubspec.lock'));
      }
    } catch (_) {}
    // Pub records every package_config that used this cache.
    try {
      for (final f in Directory(
        p.join(pubCache, 'active_roots'),
      ).listSync(recursive: true).whereType<File>()) {
        try {
          final data = jsonDecode(f.readAsStringSync()) as Map;
          final config = Uri.parse(
            data['package_config'] as String,
          ).toFilePath();
          usage.pubKeep.addAll(_packageConfigFolders(config));
        } catch (_) {}
      }
    } catch (_) {}
  }
  return usage;
}

/// Gradle's per-version folders: version -> [caches/<v>, daemon/<v>, wrapper dist].
Map<String, List<String>> gradleVersionDirs(String gradleHome) {
  final result = <String, List<String>>{};
  final version = RegExp(r'^\d+\.\d+(\.\d+)?([-.][\w]+)*$');
  for (final sub in ['caches', 'daemon', 'notifications']) {
    try {
      for (final d in Directory(
        p.join(gradleHome, sub),
      ).listSync().whereType<Directory>()) {
        final name = p.basename(d.path);
        if (version.hasMatch(name)) (result[name] ??= []).add(d.path);
      }
    } catch (_) {}
  }
  try {
    final dist = RegExp(r'^gradle-(.+)-(all|bin)$');
    for (final d in Directory(
      p.join(gradleHome, 'wrapper', 'dists'),
    ).listSync().whereType<Directory>()) {
      final m = dist.firstMatch(p.basename(d.path));
      if (m != null) (result[m.group(1)!] ??= []).add(d.path);
    }
  } catch (_) {}
  return result;
}

/// Pub cache package folders not in [keep].
List<String> unusedPubPackages(String pubCache, Set<String> keep) {
  final unused = <String>[];
  try {
    for (final host in Directory(
      p.join(pubCache, 'hosted'),
    ).listSync().whereType<Directory>()) {
      for (final pkg in host.listSync().whereType<Directory>()) {
        if (!keep.contains(p.basename(pkg.path))) unused.add(pkg.path);
      }
    }
  } catch (_) {}
  return unused;
}
