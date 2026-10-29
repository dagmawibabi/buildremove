import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;

import 'util.dart';

/// Generated folders inside a Flutter/Dart project, relative to its root.
/// All of these are recreated by `flutter pub get` / `flutter build`.
const artifactPaths = [
  'build',
  '.dart_tool',
  'android/.gradle',
  'android/.kotlin',
  'android/build',
  'android/app/build',
  'android/app/.cxx',
  'ios/Pods',
  'ios/.symlinks',
  'ios/Flutter/ephemeral',
  'macos/Pods',
  'macos/Flutter/ephemeral',
  'windows/flutter/ephemeral',
  'linux/flutter/ephemeral',
];

/// Folders never worth walking into while looking for projects.
const _skipNames = {
  'node_modules',
  '.git',
  '.hg',
  '.svn',
  r'$recycle.bin',
  'system volume information',
  'appdata',
  '.pub-cache',
  '.gradle',
  '.dartserver',
  '.android',
  'fvm',
  '.fvm',
  '.puro',
  '.trash',
  '.npm',
  '.pnpm-store',
  '.buildremove',
  '.cargo',
  '.rustup',
  '.nuget',
  '.m2',
  '.vscode',
  '.cursor',
  'pods',
};

/// System folders skipped only when they sit directly under a drive root.
const _skipAtDriveRoot = {
  'windows',
  'program files',
  'program files (x86)',
  'programdata',
  'recovery',
  r'$windows.~bt',
  r'$windows.~ws',
  r'$winreagent',
  'proc',
  'sys',
  'dev',
  'system',
  'library',
  'private',
  'usr',
  'bin',
  'sbin',
};

/// One generated folder inside a project, such as `build/`.
class Artifact {
  /// Creates an artifact at [path] taking [size] bytes.
  Artifact(this.path, this.size);

  /// Absolute path of the folder.
  final String path;

  /// Total size of the files in it, in bytes.
  final int size;

  /// JSON form, as stored in the scan cache.
  Map<String, Object> toJson() => {'path': path, 'size': size};

  /// Reads an artifact written by [toJson].
  factory Artifact.fromJson(Map json) =>
      Artifact(json['path'] as String, json['size'] as int);
}

/// A Flutter or Dart project with build output that can be cleaned.
class Project {
  /// Creates a project. Usually returned by [scanProjects].
  Project({
    required this.root,
    required this.name,
    required this.isFlutter,
    required this.artifacts,
    required this.lastBuild,
  });

  /// Folder that holds the project's `pubspec.yaml`.
  final String root;

  /// Package name from the pubspec.
  final String name;

  /// Whether the project depends on the Flutter SDK.
  final bool isFlutter;

  /// Generated folders found in the project, from [artifactPaths].
  final List<Artifact> artifacts;

  /// When `build/` or `.dart_tool/` last changed, if either exists.
  final DateTime? lastBuild;

  /// Bytes freed by removing all [artifacts].
  int get totalSize => artifacts.fold(0, (s, a) => s + a.size);

  /// Size of the artifact at [relative] (e.g. `'build'`), or 0.
  int sizeOf(String relative) => artifacts
      .where((a) => p.equals(a.path, p.join(root, relative)))
      .fold(0, (s, a) => s + a.size);

  /// JSON form, as stored in the scan cache.
  Map<String, Object?> toJson() => {
    'root': root,
    'name': name,
    'isFlutter': isFlutter,
    'lastBuild': lastBuild?.toIso8601String(),
    'artifacts': [for (final a in artifacts) a.toJson()],
  };

  /// Reads a project written by [toJson].
  factory Project.fromJson(Map json) => Project(
    root: json['root'] as String,
    name: json['name'] as String,
    isFlutter: json['isFlutter'] as bool,
    lastBuild: json['lastBuild'] == null
        ? null
        : DateTime.parse(json['lastBuild'] as String),
    artifacts: [
      for (final a in json['artifacts'] as List) Artifact.fromJson(a as Map),
    ],
  );
}

class ProjectInfo {
  ProjectInfo(this.name, this.isFlutter);
  final String name;
  final bool isFlutter;
}

/// Reads a pubspec and reports the package name and whether it uses Flutter.
ProjectInfo parsePubspec(String content, String fallbackName) {
  final name =
      RegExp(
        r'^name:\s*([\w-]+)',
        multiLine: true,
      ).firstMatch(content)?.group(1) ??
      fallbackName;
  final isFlutter = RegExp(
    r'^\s+sdk:\s*["\x27]?flutter',
    multiLine: true,
  ).hasMatch(content);
  return ProjectInfo(name, isFlutter);
}

String projectName(String root) {
  try {
    return parsePubspec(
      File(p.join(root, 'pubspec.yaml')).readAsStringSync(),
      p.basename(root),
    ).name;
  } catch (_) {
    return p.basename(root);
  }
}

class _DirInfo {
  _DirInfo(this.isProject, this.subdirs);
  final bool isProject;
  final List<String> subdirs;
}

/// Lists [dir] and decides which subfolders are worth walking into.
_DirInfo? _inspect(String dir) {
  List<FileSystemEntity> children;
  try {
    children = Directory(dir).listSync(followLinks: false);
  } catch (_) {
    return null;
  }
  final names = {for (final c in children) p.basename(c.path).toLowerCase()};
  // A Flutter SDK checkout: full of pubspecs, none of them yours.
  if (names.contains('bin') &&
      names.contains('packages') &&
      Directory(p.join(dir, 'packages', 'flutter_tools')).existsSync()) {
    return _DirInfo(false, const []);
  }
  final isProject = names.contains('pubspec.yaml');
  final atDriveRoot = p.dirname(dir) == dir;
  final subdirs = <String>[];
  for (final child in children) {
    if (child is! Directory) continue;
    final name = p.basename(child.path).toLowerCase();
    if (_skipNames.contains(name)) continue;
    if (atDriveRoot && _skipAtDriveRoot.contains(name)) continue;
    // Inside a project, don't walk into its generated output.
    if (isProject && (name == 'build' || name == '.dart_tool')) continue;
    subdirs.add(child.path);
  }
  return _DirInfo(isProject, subdirs);
}

/// Single-threaded walk of [roots] returning every folder with a pubspec.yaml.
List<String> walkForProjects(List<String> roots) {
  final found = <String>[];
  final stack = [...roots];
  while (stack.isNotEmpty) {
    final dir = stack.removeLast();
    final info = _inspect(dir);
    if (info == null) continue;
    if (info.isProject) found.add(dir);
    stack.addAll(info.subdirs);
  }
  return found;
}

/// Walks [roots] in parallel isolates and returns all project roots.
Future<List<String>> findProjectRoots(List<String> roots) async {
  final found = <String>{};
  // Expand the top levels here to get enough independent chunks of work.
  var frontier = roots.map(p.normalize).toList();
  for (var depth = 0; depth < 3 && frontier.length < cpuCount * 4; depth++) {
    final next = <String>[];
    for (final dir in frontier) {
      final info = _inspect(dir);
      if (info == null) continue;
      if (info.isProject) found.add(dir);
      next.addAll(info.subdirs);
    }
    frontier = next;
  }

  var done = 0;
  final parts = await pooled(frontier, (String dir) async {
    final r = await Isolate.run(() => walkForProjects([dir]));
    status(dim('Scanning (${++done}/${frontier.length})  $dir'));
    return r;
  }, concurrency: cpuCount);
  clearStatus();
  for (final part in parts) {
    found.addAll(part);
  }
  return found.toList()..sort();
}

/// Measures the artifacts of the project at [root]. Returns null when it has
/// nothing to clean.
Project? measureProjectSync(String root) {
  String content;
  try {
    content = File(p.join(root, 'pubspec.yaml')).readAsStringSync();
  } catch (_) {
    return null;
  }
  final info = parsePubspec(content, p.basename(root));

  final artifacts = <Artifact>[];
  DateTime? lastBuild;
  for (final rel in artifactPaths) {
    final full = p.join(root, rel);
    if (!Directory(full).existsSync()) continue;
    final size = dirSizeSync(full);
    if (size == 0) continue;
    artifacts.add(Artifact(full, size));
    if (rel == 'build' || rel == '.dart_tool') {
      try {
        final m = Directory(full).statSync().modified;
        if (lastBuild == null || m.isAfter(lastBuild)) lastBuild = m;
      } catch (_) {}
    }
  }
  if (artifacts.isEmpty) return null;
  return Project(
    root: root,
    name: info.name,
    isFlutter: info.isFlutter,
    artifacts: artifacts,
    lastBuild: lastBuild,
  );
}

Future<Project?> measureProject(String root) =>
    Isolate.run(() => measureProjectSync(root));

/// What [scanProjects] found.
class ScanResult {
  /// Creates a result.
  ScanResult(this.projectRoots, this.projects);

  /// Every folder with a pubspec.yaml, including ones with nothing to clean.
  final List<String> projectRoots;

  /// Projects with artifacts, largest first.
  final List<Project> projects;
}

/// Finds every project under [roots] and measures its artifacts, using
/// parallel isolates. Prints progress to the terminal.
Future<ScanResult> scanProjects(List<String> roots) async {
  final projectRoots = await findProjectRoots(roots);
  stdout.writeln(
    dim(
      'Found ${projectRoots.length} pubspec.yaml projects, measuring artifacts...',
    ),
  );
  var done = 0;
  final measured = await pooled(projectRoots, (String root) async {
    final r = await measureProject(root);
    status(dim('Measured ${++done}/${projectRoots.length}  $root'));
    return r;
  }, concurrency: cpuCount);
  clearStatus();
  final projects = measured.whereType<Project>().toList()
    ..sort((a, b) => b.totalSize.compareTo(a.totalSize));
  return ScanResult(projectRoots, projects);
}
