// buildremove is mainly a command-line tool:
//
//   dart pub global activate buildremove
//   buildremove
//
// The scanning and cleaning used by the CLI can also be called from Dart.
// This example lists the Flutter/Dart projects under a folder and how much
// space their build output takes, without deleting anything.
import 'dart:io';

import 'package:buildremove/buildremove.dart';

Future<void> main(List<String> args) async {
  final root = args.isEmpty ? Directory.current.path : args.first;
  final result = await scanProjects([root]);

  print('${result.projectRoots.length} projects under $root');
  for (final project in result.projects) {
    print(
      '${formatBytes(project.totalSize).padLeft(10)}  ${project.name}  '
      '${project.root}',
    );
  }

  // To actually free the space:
  // await cleanProject(result.projects.first, CleanMode.delete);
}
