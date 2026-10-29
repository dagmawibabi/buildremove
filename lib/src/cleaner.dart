import 'dart:io';

import 'package:path/path.dart' as p;

import 'scanner.dart';
import 'util.dart';

/// How [cleanProject] removes a project's artifacts.
enum CleanMode {
  /// `flutter clean` (or `fvm flutter clean`), then delete leftovers it
  /// doesn't touch such as android/.gradle and ios/Pods.
  flutterClean,

  /// Delete the artifact folders directly. Faster, no Flutter needed.
  delete,
}

/// Outcome of [cleanProject].
class CleanResult {
  /// Creates a result.
  CleanResult(this.project, this.freed, this.errors);

  /// The project that was cleaned.
  final Project project;

  /// Bytes freed (estimated from the scan).
  final int freed;

  /// Problems such as a failed `flutter clean` or a folder in use.
  final List<String> errors;
}

bool _usesFvm(String root) =>
    File(p.join(root, '.fvmrc')).existsSync() ||
    Directory(p.join(root, '.fvm')).existsSync();

/// Removes [project]'s artifacts using [mode].
///
/// With [hasFvm], projects pinned with FVM are cleaned with
/// `fvm flutter clean`. With [dryRun], nothing is deleted.
Future<CleanResult> cleanProject(
  Project project,
  CleanMode mode, {
  bool hasFvm = false,
  bool dryRun = false,
}) async {
  final errors = <String>[];
  if (dryRun) return CleanResult(project, project.totalSize, errors);

  if (mode == CleanMode.flutterClean && project.isFlutter) {
    final useFvm = hasFvm && _usesFvm(project.root);
    final exe = useFvm ? 'fvm' : 'flutter';
    final args = useFvm ? ['flutter', 'clean'] : ['clean'];
    try {
      final r = await Process.run(
        exe,
        args,
        workingDirectory: project.root,
        runInShell: true,
      );
      if (r.exitCode != 0) {
        errors.add(
          '$exe ${args.join(' ')} exited ${r.exitCode}: '
          '${(r.stderr as String).trim().split('\n').first}',
        );
      }
    } catch (e) {
      errors.add('could not run $exe: $e');
    }
  }

  // Remove whatever is left (everything, in delete mode).
  var freed = 0;
  for (final a in project.artifacts) {
    if (await deletePath(a.path)) {
      freed += a.size;
    } else {
      errors.add('could not fully delete ${a.path}');
    }
  }
  return CleanResult(project, freed, errors);
}
