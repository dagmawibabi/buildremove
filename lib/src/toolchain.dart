import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'util.dart';

class FlutterSdk {
  FlutterSdk(this.root, this.version, this.channel, {this.source = ''});
  final String root;
  final String? version;
  final String? channel;
  final String source;
}

/// A deletable cache or install, with a hint about what removing it means.
class CacheEntry {
  CacheEntry(
    this.label,
    String path,
    this.note, {
    this.size = 0,
    this.tag = '',
    this.suggested = false,
  }) : paths = [path];
  CacheEntry.multi(
    this.label,
    this.paths,
    this.note, {
    this.size = 0,
    this.tag = '',
    this.suggested = false,
  });

  final String label;
  final List<String> paths;
  final String note;
  int size;

  /// Usage info such as "used by 2: app, other".
  String tag;

  /// Not referenced by any known project, so a good candidate.
  bool suggested;

  String get path => paths.first;
}

/// Reads the version of the Flutter SDK at [root] without running Flutter.
FlutterSdk readSdk(String root, {String source = ''}) {
  String? version;
  String? channel;
  final jsonFile = File(p.join(root, 'bin', 'cache', 'flutter.version.json'));
  try {
    if (jsonFile.existsSync()) {
      final data = jsonDecode(jsonFile.readAsStringSync()) as Map;
      version = (data['flutterVersion'] ?? data['frameworkVersion'])
          ?.toString();
      channel = data['channel']?.toString();
    }
  } catch (_) {}
  if (version == null) {
    final legacy = File(p.join(root, 'version'));
    if (legacy.existsSync()) version = legacy.readAsStringSync().trim();
  }
  return FlutterSdk(root, version, channel, source: source);
}

bool isFlutterSdk(String dir) =>
    File(
      p.join(dir, 'bin', Platform.isWindows ? 'flutter.bat' : 'flutter'),
    ).existsSync() &&
    Directory(p.join(dir, 'packages', 'flutter_tools')).existsSync();

/// Flutter SDKs reachable from PATH and FLUTTER_ROOT.
Future<List<FlutterSdk>> findPathSdks() async {
  final roots = <String, String>{};
  for (final exe in await which('flutter')) {
    final root = p.dirname(p.dirname(File(exe).resolveSymbolicLinksSync()));
    if (isFlutterSdk(root)) roots.putIfAbsent(p.normalize(root), () => 'PATH');
  }
  final envRoot = env('FLUTTER_ROOT');
  if (envRoot != null && isFlutterSdk(envRoot)) {
    roots.putIfAbsent(p.normalize(envRoot), () => 'FLUTTER_ROOT');
  }
  return [for (final e in roots.entries) readSdk(e.key, source: e.value)];
}

/// Folders where FVM keeps its SDK versions.
List<String> fvmCacheDirs() {
  final h = home();
  final candidates = <String>[
    if (env('FVM_CACHE_PATH') != null) env('FVM_CACHE_PATH')!,
    if (env('FVM_HOME') != null) env('FVM_HOME')!,
    p.join(h, 'fvm'),
    p.join(h, '.fvm'),
    if (env('LOCALAPPDATA') != null) p.join(env('LOCALAPPDATA')!, 'fvm'),
  ];
  // FVM 3 can store a custom cachePath in its global settings file.
  for (final settings in [
    if (env('APPDATA') != null) p.join(env('APPDATA')!, 'fvm', '.fvmrc'),
    p.join(h, '.config', 'fvm', '.fvmrc'),
    p.join(h, 'fvm', '.fvmrc'),
  ]) {
    try {
      final data = jsonDecode(File(settings).readAsStringSync()) as Map;
      final c = data['cachePath'];
      if (c is String && c.isNotEmpty) candidates.insert(0, c);
    } catch (_) {}
  }
  final result = <String>[];
  for (final c in candidates) {
    final versions = p.basename(c) == 'versions' ? c : p.join(c, 'versions');
    if (Directory(versions).existsSync() &&
        !result.any((r) => p.equals(r, versions))) {
      result.add(versions);
    }
  }
  return result;
}

/// Other tools that keep their own Flutter SDK copies.
List<String> otherSdkDirs() {
  final h = home();
  final dirs = <String>[];
  for (final parent in [
    p.join(h, '.puro', 'envs'),
    p.join(h, '.airreload', 'sdks'),
    p.join(h, 'snap', 'flutter', 'common'),
  ]) {
    final d = Directory(parent);
    if (!d.existsSync()) continue;
    for (final child in d.listSync().whereType<Directory>()) {
      for (final candidate in [child.path, p.join(child.path, 'flutter')]) {
        if (isFlutterSdk(candidate)) dirs.add(candidate);
      }
    }
  }
  return dirs;
}

String? androidSdkDir() {
  final h = home();
  for (final c in [
    env('ANDROID_HOME'),
    env('ANDROID_SDK_ROOT'),
    if (env('LOCALAPPDATA') != null)
      p.join(env('LOCALAPPDATA')!, 'Android', 'Sdk'),
    p.join(h, 'Library', 'Android', 'sdk'),
    p.join(h, 'Android', 'Sdk'),
  ]) {
    if (c != null && Directory(c).existsSync()) return c;
  }
  return null;
}

String pubCacheDir() {
  final custom = env('PUB_CACHE');
  if (custom != null) return custom;
  if (Platform.isWindows && env('LOCALAPPDATA') != null) {
    return p.join(env('LOCALAPPDATA')!, 'Pub', 'Cache');
  }
  return p.join(home(), '.pub-cache');
}

/// Dev caches that Flutter/Android builds fill up. Only existing ones.
List<CacheEntry> knownCaches() {
  final h = home();
  final gradleHome = env('GRADLE_USER_HOME') ?? p.join(h, '.gradle');
  final local = env('LOCALAPPDATA');
  final entries = <CacheEntry>[
    CacheEntry(
      'Pub package cache',
      pubCacheDir(),
      'Dart/Flutter packages. Projects re-download on next `pub get`.',
    ),
    CacheEntry(
      'Gradle caches',
      p.join(gradleHome, 'caches'),
      'Android build cache. Re-downloaded on next Android build (slower first build).',
    ),
    CacheEntry(
      'Gradle wrapper distributions',
      p.join(gradleHome, 'wrapper', 'dists'),
      'Downloaded Gradle versions. Re-downloaded when needed.',
    ),
    CacheEntry(
      'Gradle daemon logs',
      p.join(gradleHome, 'daemon'),
      'Logs and daemon state. Safe to delete.',
    ),
    CacheEntry(
      'Dart analysis server cache',
      p.join(h, '.dartServer'),
      'IDE analyzer cache. Rebuilt automatically.',
    ),
    if (local != null)
      CacheEntry(
        'Dart analysis server cache',
        p.join(local, '.dartServer'),
        'IDE analyzer cache. Rebuilt automatically.',
      ),
    CacheEntry(
      'Android emulators (AVDs)',
      p.join(h, '.android', 'avd'),
      'Emulator images and their data. Deleting removes the emulators.',
    ),
    if (Platform.isMacOS) ...[
      CacheEntry(
        'Xcode DerivedData',
        p.join(h, 'Library', 'Developer', 'Xcode', 'DerivedData'),
        'Xcode build output. Rebuilt automatically.',
      ),
      CacheEntry(
        'CocoaPods cache',
        p.join(h, 'Library', 'Caches', 'CocoaPods'),
        'Pod downloads. Re-downloaded on next `pod install`.',
      ),
    ],
  ];
  final seen = <String>{};
  return entries
      .where(
        (e) =>
            Directory(e.path).existsSync() &&
            seen.add(p.normalize(e.path).toLowerCase()),
      )
      .toList();
}
