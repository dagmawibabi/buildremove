import 'dart:io';

import 'package:path/path.dart' as p;

import 'cleaner.dart';
import 'picker.dart';
import 'prompt.dart';
import 'scanner.dart';
import 'store.dart';
import 'toolchain.dart';
import 'usage.dart';
import 'util.dart';

class Drive {
  Drive(this.root, {this.free, this.total});
  final String root;
  final int? free;
  final int? total;
}

Future<List<Drive>> listDrives() async {
  if (Platform.isWindows) {
    final space = await windowsDriveSpace();
    final drives = <Drive>[];
    for (var c = 'C'.codeUnitAt(0); c <= 'Z'.codeUnitAt(0); c++) {
      final root = '${String.fromCharCode(c)}:\\';
      if (!Directory(root).existsSync()) continue;
      final s = space[root];
      drives.add(Drive(root, free: s?.$1, total: s?.$2));
    }
    return drives;
  }
  final roots = <String>[home(), '/'];
  for (final parent in ['/Volumes', '/mnt', '/media/${env('USER') ?? ''}']) {
    try {
      roots.addAll(
        Directory(parent).listSync().whereType<Directory>().map((d) => d.path),
      );
    } catch (_) {}
  }
  return roots.map((r) => Drive(r)).toList();
}

/// Multi-select with the arrow-key picker, or typed numbers when the
/// terminal can't do raw input.
Set<int> chooseMany(
  String title,
  List<String> lines, {
  String? header,
  Set<int> suggested = const {},
  bool enterPicksCurrent = false,
  String defaultValue = 'none',
  String Function(Set<int>)? summary,
}) {
  final r = pickMany(
    title,
    lines,
    header: header,
    suggested: suggested,
    enterPicksCurrent: enterPicksCurrent,
    summary: summary,
  );
  if (r != null) return r.selected;

  stdout.writeln(bold('\n$title'));
  if (header != null) stdout.writeln(dim('       $header'));
  for (var i = 0; i < lines.length; i++) {
    stdout.writeln('  ${cyan('${i + 1}'.padLeft(3))}  ${lines[i]}');
  }
  final unusedHint = suggested.isEmpty ? '' : ' / u = all unused';
  while (true) {
    final input = ask(
      'Choose ${dim('(e.g. 1,3,5-8 / all / none$unusedHint)')}',
      defaultValue: defaultValue,
    );
    if (suggested.isNotEmpty && input.toLowerCase() == 'u') return suggested;
    final sel = parseSelection(input, lines.length);
    if (sel != null) return sel;
    stdout.writeln(red('  Use numbers like 1,3,5-8, or "all" / "none".'));
  }
}

/// Lets the user choose drives, then optionally folders within each drive.
Future<List<String>> pickRoots(Store store) async {
  final last = store.lastRoots.where((r) => Directory(r).existsSync()).toList();
  if (last.isNotEmpty &&
      confirm(
        'Scan the same places as last time? ${dim(last.join(', '))}',
        defaultYes: true,
      )) {
    return last;
  }

  final drives = await listDrives();
  final picked = chooseMany(
    'Which drives?',
    [
      for (final d in drives)
        d.free == null
            ? d.root
            : '${d.root.padRight(5)} ${formatBytes(d.free!).padLeft(9)} free of ${formatBytes(d.total!)}',
    ],
    enterPicksCurrent: true,
    defaultValue: 'all',
  );

  final roots = <String>[];
  for (final i in picked.toList()..sort()) {
    final drive = drives[i].root;
    final choice = ask(
      'Scan all of $drive or pick folders? ${dim('[a]ll / [p]ick')}',
      defaultValue: 'a',
    ).toLowerCase();
    if (!choice.startsWith('p')) {
      roots.add(drive);
      continue;
    }
    List<Directory> folders;
    try {
      folders =
          Directory(drive).listSync().whereType<Directory>().where((d) {
            final n = p.basename(d.path);
            return !n.startsWith(r'$') && n != 'System Volume Information';
          }).toList()..sort(
            (a, b) => a.path.toLowerCase().compareTo(b.path.toLowerCase()),
          );
    } catch (e) {
      stdout.writeln(red('  Could not list $drive: $e'));
      continue;
    }
    final sel = chooseMany(
      'Which folders in $drive?',
      [for (final f in folders) f.path],
      enterPicksCurrent: true,
      defaultValue: 'all',
    );
    roots.addAll([for (final j in sel.toList()..sort()) folders[j].path]);
  }

  final extra = ask(
    'Extra folders to scan? ${dim('(paths separated by ";", Enter to skip)')}',
  );
  for (final path
      in extra.split(';').map((s) => s.trim().replaceAll('"', ''))) {
    if (path.isEmpty) continue;
    if (Directory(path).existsSync()) {
      roots.add(path);
    } else {
      stdout.writeln(yellow('  Skipping $path (not found)'));
    }
  }
  return roots;
}

const _projectHeader =
    '    Total      build  .dart_tool      other  Last build  Project';

String _projectLine(Project pr) {
  final build = pr.sizeOf('build');
  final tool = pr.sizeOf('.dart_tool');
  final other = pr.totalSize - build - tool;
  return '${formatBytes(pr.totalSize).padLeft(9)}  '
      '${formatBytes(build).padLeft(9)}  '
      '${formatBytes(tool).padLeft(10)}  '
      '${formatBytes(other).padLeft(9)}  '
      '${formatAge(pr.lastBuild).padRight(10)}  '
      '${pr.name}${pr.isFlutter ? '' : ' (dart)'}  ${pr.root}';
}

void printProjects(List<Project> projects) {
  stdout.writeln(bold('\n  #  $_projectHeader'));
  for (var i = 0; i < projects.length; i++) {
    stdout.writeln(
      '${cyan('${i + 1}'.padLeft(3))}  ${_projectLine(projects[i])}',
    );
  }
}

/// Asks which projects to clean. Returns (selected, newly ignored).
(Set<int>, Set<int>) _selectProjects(List<Project> projects) {
  String summary(Set<int> s) =>
      '${s.length} selected · ${formatBytes(s.fold(0, (t, i) => t + projects[i].totalSize))}';
  final r = pickMany(
    'Clean which projects?',
    [for (final pr in projects) _projectLine(pr)],
    header: _projectHeader,
    allowIgnore: true,
    summary: summary,
  );
  if (r != null) return (r.selected, r.ignored);

  printProjects(projects);
  final ignored = <int>{};
  while (true) {
    final input = ask(
      '\nClean which projects? '
      '${dim('(e.g. 1,3,5-8 / all / none; "i 2,4" ignores them for good)')}',
      defaultValue: 'none',
    );
    if (input.toLowerCase().startsWith('i ')) {
      final s = parseSelection(input.substring(2), projects.length);
      if (s == null) {
        stdout.writeln(red('  Use numbers like "i 2,4".'));
        continue;
      }
      ignored.addAll(s);
      stdout.writeln(
        dim('  Will ignore: ${s.map((i) => projects[i].name).join(', ')}'),
      );
      continue;
    }
    final s = parseSelection(input, projects.length);
    if (s != null) return (s.difference(ignored), ignored);
    stdout.writeln(red('  Use numbers like 1,3,5-8, or "all" / "none".'));
  }
}

Future<void> scanFlow(
  List<String> roots, {
  bool dryRun = false,
  bool yes = false,
  bool fresh = false,
  int? olderThanDays,
}) async {
  final store = Store.load();
  if (roots.isEmpty) roots = await pickRoots(store);
  if (roots.isEmpty) {
    stdout.writeln(yellow('Nothing to scan.'));
    return;
  }
  store.lastRoots = roots;

  List<Project> projects;
  final cached = fresh ? null : store.cachedScan(roots);
  if (cached != null &&
      (yes ||
          confirm(
            'Use results from the last scan of these folders (${formatAge(cached.time)})? '
            '${dim('n = scan again')}',
            defaultYes: true,
          ))) {
    projects = cached.projects
        .where((pr) => Directory(pr.root).existsSync())
        .toList();
  } else {
    stdout.writeln(dim('\nScanning ${roots.join(', ')} on $cpuCount threads'));
    final sw = Stopwatch()..start();
    final result = await scanProjects(roots);
    stdout.writeln(
      dim('Scan took ${(sw.elapsedMilliseconds / 1000).toStringAsFixed(1)}s'),
    );
    projects = result.projects;
    store.addKnownProjects(result.projectRoots);
    store.saveScan(roots, projects);
  }
  store.save();

  final ignoredCount = projects.where((pr) => store.isIgnored(pr.root)).length;
  projects = projects.where((pr) => !store.isIgnored(pr.root)).toList();
  if (ignoredCount > 0) {
    stdout.writeln(
      dim(
        '$ignoredCount ignored project${ignoredCount == 1 ? '' : 's'} hidden '
        '(buildremove ignored to change)',
      ),
    );
  }

  // Hide projects built recently so the one you're working on is safe.
  var days = olderThanDays;
  if (days == null && !yes) {
    final recent = projects.any(
      (pr) =>
          pr.lastBuild != null &&
          DateTime.now().difference(pr.lastBuild!).inDays < 30,
    );
    if (recent) {
      final fallback = store.olderThanDays ?? 3;
      days =
          parseDays(
            ask(
              'Hide projects built in the last how many days? ${dim('(0 = show all)')}',
              defaultValue: '$fallback',
            ),
          ) ??
          fallback;
      store.olderThanDays = days;
      store.save();
    }
  }
  if (days != null && days > 0) {
    final cutoff = DateTime.now().subtract(Duration(days: days));
    final hidden = projects
        .where((pr) => pr.lastBuild?.isAfter(cutoff) ?? false)
        .toList();
    projects = projects.where((pr) => !hidden.contains(pr)).toList();
    if (hidden.isNotEmpty) {
      stdout.writeln(
        dim(
          'Hiding ${hidden.length} built in the last $days days: '
          '${hidden.map((pr) => pr.name).join(', ')}',
        ),
      );
    }
  }

  if (projects.isEmpty) {
    stdout.writeln(green('No Flutter/Dart build artifacts to clean.'));
    return;
  }
  final reclaimable = projects.fold(0, (s, pr) => s + pr.totalSize);
  stdout.writeln(
    green(
      '\n${projects.length} projects, ${formatBytes(reclaimable)} reclaimable',
    ),
  );

  Set<int> sel;
  if (yes) {
    printProjects(projects);
    sel = {for (var i = 0; i < projects.length; i++) i};
  } else {
    final (picked, newlyIgnored) = _selectProjects(projects);
    if (newlyIgnored.isNotEmpty) {
      store.ignore(newlyIgnored.map((i) => projects[i].root));
      store.save();
      stdout.writeln(
        dim(
          'Ignored ${newlyIgnored.map((i) => projects[i].name).join(', ')} '
          'from now on.',
        ),
      );
    }
    sel = picked;
  }
  if (sel.isEmpty) return;
  final chosen = [for (final i in sel.toList()..sort()) projects[i]];

  final target = chosen.length == 1
      ? chosen.single.name
      : '${chosen.length} projects';
  var mode = CleanMode.flutterClean;
  if (!yes) {
    stdout.writeln(
      bold('\nSelected: ${chosen.map((pr) => pr.name).join(', ')}'),
    );
    stdout.writeln('How should $target be cleaned?');
    stdout.writeln(
      '  ${cyan('1')}  Run flutter clean, then remove leftovers '
      '(android/.gradle, ios/Pods, ...)',
    );
    stdout.writeln(
      '  ${cyan('2')}  Delete artifact folders directly ${dim('(faster, same result)')}',
    );
    if (ask('Method', defaultValue: '1') == '2') mode = CleanMode.delete;
  }

  final total = chosen.fold(0, (s, pr) => s + pr.totalSize);
  if (!yes &&
      !confirm(
        '${dryRun ? '[dry run] ' : ''}Clean $target and free about ${formatBytes(total)}?',
      )) {
    return;
  }

  final before = await volumeFree(chosen.map((pr) => pr.root));
  final hasFvm = (await which('fvm')).isNotEmpty;
  var freed = 0;
  for (var i = 0; i < chosen.length; i++) {
    final pr = chosen[i];
    stdout.write(
      '  [${i + 1}/${chosen.length}] ${pr.name} ${dim(pr.root)} ... ',
    );
    final r = await cleanProject(pr, mode, hasFvm: hasFvm, dryRun: dryRun);
    freed += r.freed;
    stdout.writeln(
      r.errors.isEmpty
          ? green(formatBytes(r.freed))
          : yellow('${formatBytes(r.freed)} (${r.errors.join('; ')})'),
    );
  }
  stdout.writeln(
    bold(green('\n${dryRun ? 'Would free' : 'Freed'} ${formatBytes(freed)}')),
  );
  if (!dryRun) {
    printFreeChange(before, await volumeFree(chosen.map((pr) => pr.root)));
    store.forgetFromScan(chosen.map((pr) => pr.root));
    store.save();
  }
}

/// Makes sure there are known projects to check SDK/cache usage against.
Future<List<String>> _knownProjects(
  Store store,
  List<String> fvmDirs,
  bool interactive,
) async {
  store.addKnownProjects(fvmKnownProjects(fvmDirs));
  var known = store.knownProjects;
  if (known.isEmpty && interactive) {
    stdout.writeln(
      '\nTo tell which SDK versions and cached packages are still used, '
      'buildremove needs to know where your projects are.',
    );
    if (confirm('Look for projects now?', defaultYes: true)) {
      final roots = await pickRoots(store);
      if (roots.isNotEmpty) {
        store.lastRoots = roots;
        stdout.writeln(dim('Looking for projects on $cpuCount threads...'));
        store.addKnownProjects(await findProjectRoots(roots));
        known = store.knownProjects;
      }
    }
  }
  store.save();
  return known;
}

Future<void> infoFlow({bool dryRun = false, bool interactive = true}) async {
  final store = Store.load();
  final fvmDirs = fvmCacheDirs();
  final known = await _knownProjects(store, fvmDirs, interactive);
  final deletable = <CacheEntry>[];

  stdout.writeln(dim('\nMeasuring SDKs and caches on $cpuCount threads...'));
  final pathSdks = await findPathSdks();
  final fvmVersions = [
    for (final dir in fvmDirs)
      ...Directory(dir).listSync().whereType<Directory>().map((d) => d.path),
  ];
  final usage = analyzeUsage(
    known,
    defaultSdk: pathSdks.isEmpty ? null : pathSdks.first.root,
    fvmVersionDirs: fvmDirs,
    sdkRoots: [...pathSdks.map((s) => s.root), ...fvmVersions],
    pubCache: pubCacheDir(),
  );
  stdout.writeln(
    dim(
      usage.known
          ? 'Checking usage against ${known.length} known projects (from your scans and FVM).'
          : 'No known projects yet, so usage can\'t be checked. Run a scan first.',
    ),
  );

  // Flutter on PATH.
  final sdkSizes = await sizesOf([for (final s in pathSdks) s.root]);
  stdout.writeln(bold('\nFlutter on PATH'));
  if (pathSdks.isEmpty) stdout.writeln(dim('  flutter not found on PATH'));
  for (var i = 0; i < pathSdks.length; i++) {
    final s = pathSdks[i];
    stdout.writeln('  ${s.root}${i == 0 ? green(' (active)') : ''}');
    stdout.writeln(
      dim(
        '    version ${s.version ?? '?'}  channel ${s.channel ?? '?'}  '
        '${formatBytes(sdkSizes[i])}  via ${s.source}',
      ),
    );
  }

  // FVM.
  stdout.writeln(bold('\nFVM'));
  final fvmExe = await which('fvm');
  stdout.writeln(
    fvmExe.isEmpty
        ? dim('  fvm not on PATH')
        : '  executable: ${fvmExe.join(', ')}',
  );
  if (fvmDirs.isEmpty) stdout.writeln(dim('  no FVM versions folder found'));
  for (final dir in fvmDirs) {
    stdout.writeln('  versions in $dir');
    String? globalTarget;
    try {
      final link = Link(p.join(p.dirname(dir), 'default'));
      if (link.existsSync()) globalTarget = p.normalize(link.targetSync());
    } catch (_) {}
    final versions = Directory(
      dir,
    ).listSync().whereType<Directory>().map((d) => d.path).toList();
    final sizes = await sizesOf(versions);
    for (var i = 0; i < versions.length; i++) {
      final v = versions[i];
      final name = p.basename(v);
      final sdk = readSdk(v);
      final isGlobal = globalTarget != null && p.equals(globalTarget, v);
      final tag = isGlobal ? 'FVM global' : usage.tag(usage.fvm, name);
      stdout.writeln(
        '    ${name.padRight(16)} ${formatBytes(sizes[i]).padLeft(9)}'
        '${sdk.version != null && sdk.version != name ? dim('  (${sdk.version})') : ''}'
        '  ${_tagColor(tag)}',
      );
      deletable.add(
        CacheEntry(
          'FVM Flutter $name',
          v,
          'Projects pinned to it re-install it with `fvm install`.',
          size: sizes[i],
          tag: tag,
          suggested: !isGlobal && usage.unused(usage.fvm, name),
        ),
      );
    }
  }

  // Other tools' SDK copies.
  final others = otherSdkDirs();
  if (others.isNotEmpty) {
    stdout.writeln(bold('\nOther Flutter SDK copies'));
    final sizes = await sizesOf(others);
    for (var i = 0; i < others.length; i++) {
      final sdk = readSdk(others[i]);
      stdout.writeln(
        '  ${others[i]}  ${dim('${sdk.version ?? '?'}  ${formatBytes(sizes[i])}')}',
      );
      deletable.add(
        CacheEntry(
          'Flutter SDK copy ${sdk.version ?? ''}'.trim(),
          others[i],
          'Managed by another tool; it may re-download it.',
          size: sizes[i],
        ),
      );
    }
  }

  // Android SDK.
  final android = androidSdkDir();
  stdout.writeln(bold('\nAndroid SDK'));
  if (android == null) {
    stdout.writeln(dim('  not found'));
  } else {
    stdout.writeln('  $android');
    for (final sub in [
      'ndk',
      'build-tools',
      'platforms',
      'system-images',
      'emulator',
      'cmake',
      'sources',
    ]) {
      final dir = Directory(p.join(android, sub));
      if (!dir.existsSync()) continue;
      final children = sub == 'emulator'
          ? [dir.path]
          : dir.listSync().whereType<Directory>().map((d) => d.path).toList();
      final sizes = await sizesOf(children);
      final total = sizes.fold(0, (a, b) => a + b);
      if (sub == 'ndk') {
        stdout.writeln(
          '    ${sub.padRight(14)} ${formatBytes(total).padLeft(9)}',
        );
        for (var i = 0; i < children.length; i++) {
          final v = p.basename(children[i]);
          final tag = usage.tag(usage.ndk, v);
          stdout.writeln(
            '      ${v.padRight(18)} ${formatBytes(sizes[i]).padLeft(9)}  ${_tagColor(tag)}',
          );
          deletable.add(
            CacheEntry(
              'Android NDK $v',
              children[i],
              'Reinstall from Android Studio > SDK Manager if a build needs it.',
              size: sizes[i],
              tag: tag,
              suggested: usage.unused(usage.ndk, v),
            ),
          );
        }
        continue;
      }
      final names = sub == 'emulator'
          ? ''
          : dim('  ${children.map(p.basename).join(', ')}');
      stdout.writeln(
        '    ${sub.padRight(14)} ${formatBytes(total).padLeft(9)}$names',
      );
      if (sub == 'system-images' || sub == 'build-tools') {
        for (var i = 0; i < children.length; i++) {
          deletable.add(
            CacheEntry(
              'Android $sub ${p.basename(children[i])}',
              children[i],
              'Reinstall from Android Studio > SDK Manager if a build needs it.',
              size: sizes[i],
            ),
          );
        }
      }
    }
  }

  // Gradle, per version.
  final gradleHome = env('GRADLE_USER_HOME') ?? p.join(home(), '.gradle');
  final gradleVersions = gradleVersionDirs(gradleHome);
  if (gradleVersions.isNotEmpty) {
    stdout.writeln(bold('\nGradle versions') + dim('  ($gradleHome)'));
    final versions = gradleVersions.keys.toList()..sort();
    final sizes = await pooled(
      versions,
      (String v) => totalSizeOf(gradleVersions[v]!),
      concurrency: cpuCount,
    );
    for (var i = 0; i < versions.length; i++) {
      if (sizes[i] == 0) continue; // only empty notification folders
      final v = versions[i];
      final tag = usage.tag(usage.gradle, v);
      stdout.writeln(
        '    ${v.padRight(16)} ${formatBytes(sizes[i]).padLeft(9)}  ${_tagColor(tag)}',
      );
      deletable.add(
        CacheEntry.multi(
          'Gradle $v (cache, daemon, wrapper)',
          gradleVersions[v]!,
          'Re-downloaded if a project needs this Gradle version.',
          size: sizes[i],
          tag: tag,
          suggested: usage.unused(usage.gradle, v),
        ),
      );
    }
  }

  // Caches.
  final caches = knownCaches();
  final cacheSizes = await sizesOf([for (final c in caches) c.path]);
  for (var i = 0; i < caches.length; i++) {
    caches[i].size = cacheSizes[i];
  }
  caches.sort((a, b) => b.size.compareTo(a.size));
  stdout.writeln(bold('\nCaches'));
  for (final c in caches) {
    stdout.writeln(
      '  ${c.label.padRight(30)} ${formatBytes(c.size).padLeft(9)}  ${dim(c.path)}',
    );
  }
  deletable.addAll(caches);

  // Pub packages no known project uses.
  if (usage.known) {
    final unused = unusedPubPackages(pubCacheDir(), usage.pubKeep);
    if (unused.isNotEmpty) {
      final size = await totalSizeOf(unused);
      stdout.writeln(
        '  ${'Pub cache, unused versions'.padRight(30)} ${formatBytes(size).padLeft(9)}  '
        '${dim('${unused.length} not in any known project\'s pubspec.lock')}',
      );
      deletable.add(
        CacheEntry.multi(
          'Pub cache: ${unused.length} unused package versions',
          unused,
          'Not used by any known project; `pub get` re-downloads if needed.',
          size: size,
          tag: 'not used by any known project',
          suggested: true,
        ),
      );
    }
  }

  deletable
    ..removeWhere((d) => d.size == 0)
    ..sort((a, b) => b.size.compareTo(a.size));
  if (!interactive || deletable.isEmpty) return;

  final suggested = {
    for (var i = 0; i < deletable.length; i++)
      if (deletable[i].suggested) i,
  };
  if (suggested.isNotEmpty) {
    final s = suggested.fold(0, (t, i) => t + deletable[i].size);
    stdout.writeln(
      green(
        '\n${suggested.length} items (${formatBytes(s)}) aren\'t used by any known project.',
      ),
    );
  }
  final sel = chooseMany(
    'Delete which of these? (largest first)',
    [
      for (final d in deletable)
        '${formatBytes(d.size).padLeft(9)}  ${d.label}${d.tag.isEmpty ? '' : '  [${d.tag}]'}  - ${d.note}',
    ],
    suggested: suggested,
    summary: (s) =>
        '${s.length} selected · ${formatBytes(s.fold(0, (t, i) => t + deletable[i].size))}',
  );
  if (sel.isEmpty) return;
  final chosen = [for (final i in sel.toList()..sort()) deletable[i]];
  await _deleteEntries(chosen, dryRun: dryRun);
}

String _tagColor(String tag) => tag.startsWith('not used')
    ? green(tag)
    : tag.isEmpty
    ? ''
    : yellow(tag);

Future<void> _deleteEntries(
  List<CacheEntry> chosen, {
  required bool dryRun,
}) async {
  // Don't count an entry twice when it lies inside another chosen one.
  bool covered(CacheEntry e) => chosen.any(
    (o) =>
        !identical(o, e) &&
        e.paths.every((x) => o.paths.any((op) => p.isWithin(op, x))),
  );
  final total = chosen.where((e) => !covered(e)).fold(0, (s, c) => s + c.size);

  stdout.writeln();
  for (final c in chosen) {
    stdout.writeln(
      '  - ${c.label}  ${dim(c.paths.length == 1 ? c.path : '${c.paths.length} folders')}',
    );
  }
  stdout.writeln(
    '\n  ${cyan('1')}  Delete permanently ${dim('(frees the space now)')}',
  );
  stdout.writeln(
    '  ${cyan('2')}  Move to the ${Platform.isWindows ? 'Recycle Bin' : 'Trash'} '
    '${dim('(can be restored; space is freed only when you empty it, and it is slower)')}',
  );
  final toTrash = ask('Method', defaultValue: '1') == '2';
  if (ask(
        '${dryRun ? '[dry run] ' : ''}Type "yes" to ${toTrash ? 'move' : 'delete'} '
        'these (${formatBytes(total)})',
      ).toLowerCase() !=
      'yes') {
    stdout.writeln(dim('Cancelled.'));
    return;
  }

  final allPaths = [for (final c in chosen) ...c.paths];
  final before = await volumeFree(allPaths);
  var done = 0;
  for (final c in chosen) {
    stdout.write('  ${c.label} ... ');
    var ok = true;
    if (!dryRun) {
      if (toTrash) {
        final failed = await trashPaths(c.paths);
        ok = failed.isEmpty;
      } else {
        for (final x in c.paths) {
          ok = await deletePath(x) && ok;
        }
      }
    }
    if (ok && !covered(c)) done += c.size;
    stdout.writeln(ok ? green('done') : yellow('partly done (files in use?)'));
  }
  final verb = dryRun
      ? 'Would free'
      : toTrash
      ? 'Moved'
      : 'Freed';
  stdout.writeln(bold(green('\n$verb about ${formatBytes(done)}')));
  if (!dryRun && !toTrash) printFreeChange(before, await volumeFree(allPaths));
  if (toTrash && !dryRun) {
    stdout.writeln(
      dim(
        'Empty the ${Platform.isWindows ? 'Recycle Bin' : 'Trash'} to actually free the space.',
      ),
    );
  }
}

/// Shows ignored projects and lets the user un-ignore some.
Future<void> ignoredFlow() async {
  final store = Store.load();
  final ignored = store.ignored;
  if (ignored.isEmpty) {
    stdout.writeln(
      dim('No ignored projects. Press "i" in the project list to ignore one.'),
    );
    return;
  }
  final sel = chooseMany('Stop ignoring which projects?', ignored);
  if (sel.isEmpty) return;
  store.unignore([for (final i in sel) ignored[i]]);
  store.save();
  stdout.writeln(
    green(
      'Done. ${sel.length} project${sel.length == 1 ? '' : 's'} will show up again.',
    ),
  );
}

void configFlow() {
  final store = Store.load();
  stdout.writeln('${bold('Settings')} ${dim(Store.configPath)}');
  stdout.writeln(store.describe());
}

Future<void> menu({bool dryRun = false}) async {
  stdout.writeln(
    bold('buildremove') +
        dim(
          ' · find and clean Flutter build artifacts${dryRun ? '  [DRY RUN]' : ''}',
        ),
  );
  while (true) {
    stdout.writeln(
      '\n  ${cyan('1')}  Scan drives/folders for Flutter project artifacts',
    );
    stdout.writeln(
      '  ${cyan('2')}  Flutter SDKs, FVM, Android SDK, Gradle and caches (with usage)',
    );
    stdout.writeln('  ${cyan('3')}  Manage ignored projects');
    stdout.writeln('  ${cyan('q')}  Quit');
    switch (ask('Choose', defaultValue: '1').toLowerCase()) {
      case '1':
        await scanFlow([], dryRun: dryRun);
      case '2':
        await infoFlow(dryRun: dryRun);
      case '3':
        await ignoredFlow();
      case 'q' || 'quit' || 'exit':
        return;
    }
  }
}
