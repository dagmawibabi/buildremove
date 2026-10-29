import 'dart:io';

import 'package:buildremove/buildremove.dart';
import 'package:buildremove/src/prompt.dart';
import 'package:buildremove/src/scanner.dart';
import 'package:buildremove/src/usage.dart';
import 'package:buildremove/src/util.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('parseSelection', () {
    test('numbers and ranges', () {
      expect(parseSelection('1,3, 5-7', 10), {0, 2, 4, 5, 6});
      expect(parseSelection('7-5', 10), {4, 5, 6});
    });
    test('all / none', () {
      expect(parseSelection('all', 3), {0, 1, 2});
      expect(parseSelection('', 3), <int>{});
      expect(parseSelection('none', 3), <int>{});
    });
    test('rejects out of range and junk', () {
      expect(parseSelection('0', 3), isNull);
      expect(parseSelection('4', 3), isNull);
      expect(parseSelection('1-9', 3), isNull);
      expect(parseSelection('abc', 3), isNull);
    });
  });

  test('parsePubspec detects flutter', () {
    final flutter = parsePubspec(
      'name: my_app\ndependencies:\n  flutter:\n    sdk: flutter\n',
      'x',
    );
    expect(flutter.name, 'my_app');
    expect(flutter.isFlutter, isTrue);
    final dart = parsePubspec(
      'name: tool\ndependencies:\n  args: ^2.0.0\n',
      'x',
    );
    expect(dart.isFlutter, isFalse);
  });

  group('scan and clean', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('buildremove_test'));
    tearDown(() => tmp.deleteSync(recursive: true));

    void writeFile(String rel, int bytes) {
      final f = File(p.join(tmp.path, rel))..createSync(recursive: true);
      f.writeAsBytesSync(List.filled(bytes, 0));
    }

    test(
      'finds projects, skips node_modules and nested build output',
      () async {
        writeFile('app/pubspec.yaml', 10);
        writeFile('app/build/out.bin', 1000);
        writeFile('app/.dart_tool/x', 200);
        writeFile('app/android/.gradle/y', 300);
        writeFile('app/build/fake/pubspec.yaml', 1); // inside build: ignored
        writeFile('web/node_modules/pkg/pubspec.yaml', 1); // ignored
        writeFile('clean_app/pubspec.yaml', 10); // nothing to clean

        final result = await scanProjects([tmp.path]);
        expect(result.projectRoots, hasLength(2));
        expect(result.projects, hasLength(1));
        final app = result.projects.single;
        expect(app.sizeOf('build'), 1001);
        expect(app.totalSize, 1501);

        final r = await cleanProject(app, CleanMode.delete);
        expect(r.errors, isEmpty);
        expect(r.freed, 1501);
        expect(
          Directory(p.join(tmp.path, 'app', 'build')).existsSync(),
          isFalse,
        );
        expect(
          File(p.join(tmp.path, 'app', 'pubspec.yaml')).existsSync(),
          isTrue,
        );
      },
    );

    test('usage: NDK, Gradle, FVM and pub packages', () {
      final sdk = p.join(tmp.path, 'sdk');
      File(
          p.join(
            sdk,
            'packages',
            'flutter_tools',
            'gradle',
            'src',
            'main',
            'kotlin',
            'FlutterExtension.kt',
          ),
        )
        ..createSync(recursive: true)
        ..writeAsStringSync('    val ndkVersion: String = "28.2.13676358"\n');
      final app = p.join(tmp.path, 'app');
      writeFile('app/pubspec.yaml', 1);
      File(p.join(app, 'android', 'app', 'build.gradle.kts'))
        ..createSync(recursive: true)
        ..writeAsStringSync(
          'android {\n    ndkVersion = flutter.ndkVersion\n}\n',
        );
      File(
          p.join(
            app,
            'android',
            'gradle',
            'wrapper',
            'gradle-wrapper.properties',
          ),
        )
        ..createSync(recursive: true)
        ..writeAsStringSync(
          r'distributionUrl=https\://services.gradle.org/distributions/gradle-8.12-all.zip',
        );
      File(p.join(app, '.fvmrc')).writeAsStringSync('{"flutter": "3.38.6"}');
      File(p.join(app, 'pubspec.lock')).writeAsStringSync('''
packages:
  args:
    dependency: "direct main"
    description:
      name: args
      url: "https://pub.dev"
    source: hosted
    version: "2.5.0"
  flutter:
    dependency: "direct main"
    description: flutter
    source: sdk
    version: "0.0.0"
sdks:
  dart: ">=3.5.0 <4.0.0"
''');

      final usage = analyzeUsage([app], defaultSdk: sdk);
      expect(usage.ndk.keys, ['28.2.13676358']);
      expect(usage.gradle.keys, ['8.12']);
      expect(usage.fvm.keys, ['3.38.6']);
      expect(usage.pubKeep, {'args-2.5.0'});
      expect(usage.unused(usage.ndk, '30.0.1'), isTrue);

      final cache = p.join(tmp.path, 'pub');
      Directory(
        p.join(cache, 'hosted', 'pub.dev', 'args-2.5.0'),
      ).createSync(recursive: true);
      Directory(
        p.join(cache, 'hosted', 'pub.dev', 'args-2.4.0'),
      ).createSync(recursive: true);
      expect(unusedPubPackages(cache, usage.pubKeep).map(p.basename), [
        'args-2.4.0',
      ]);
    });

    test('gradle version folders are grouped', () {
      final g = p.join(tmp.path, 'gradle');
      for (final d in [
        'caches/8.12',
        'caches/modules-2',
        'daemon/8.12',
        'wrapper/dists/gradle-8.12-all',
      ]) {
        Directory(p.join(g, d)).createSync(recursive: true);
      }
      final dirs = gradleVersionDirs(g);
      expect(dirs.keys, ['8.12']);
      expect(dirs['8.12'], hasLength(3));
    });
  });

  test('parseDays', () {
    expect(parseDays('14'), 14);
    expect(parseDays('2w'), 14);
    expect(parseDays('3mo'), 90);
    expect(parseDays('soon'), isNull);
  });
}
