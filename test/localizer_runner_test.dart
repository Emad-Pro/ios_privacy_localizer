import 'dart:io';

import 'package:ios_privacy_localizer/ios_privacy_localizer.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'fixtures/fixtures.dart';

void main() {
  late Directory root;
  late IosProjectPaths paths;
  late StringBuffer output;
  const validator = PlistValidator(useNativeTools: false);

  LocalizerRunner runner() => LocalizerRunner(
        projectRoot: root.path,
        logger: LocalizerLogger.buffered(output),
        validator: validator,
      );

  Map<String, List<int>> snapshot() => <String, List<int>>{
        for (final entity in root.listSync(recursive: true))
          if (entity is File)
            p.relative(entity.path, from: root.path).replaceAll(r'\', '/'):
                entity.readAsBytesSync(),
      };

  setUp(() {
    root = Directory.systemTemp.createTempSync('ipl_run_');
    paths = IosProjectPaths(root.path);
    output = StringBuffer();
    File(p.join(root.path, 'pubspec.yaml'))
        .writeAsStringSync('name: my_app\n\n$sampleConfigYaml');
    File(paths.infoPlist)
      ..createSync(recursive: true)
      ..writeAsStringSync(flutterInfoPlist);
    File(paths.pbxproj)
      ..createSync(recursive: true)
      ..writeAsStringSync(flutterPbxproj);
    File(paths.stringsFile('en'))
      ..createSync(recursive: true)
      ..writeAsStringSync(appNameLocalizerStrings);
  });

  tearDown(() => root.deleteSync(recursive: true));

  test('end to end: writes every file and keeps app_name_localizer keys', () {
    final report = runner().run();
    expect(report.changes.map((c) => c.displayPath), <String>[
      'ios/Runner/Info.plist',
      'ios/Runner/en.lproj/InfoPlist.strings',
      'ios/Runner/ar.lproj/InfoPlist.strings',
      'ios/Runner.xcodeproj/project.pbxproj',
    ]);

    final en = File(paths.stringsFile('en')).readAsStringSync();
    expect(en, contains('"CFBundleDisplayName" = "My App";'));
    expect(en, contains('"CFBundleName" = "My App";'));
    expect(en, contains('"NSCameraUsageDescription" = "We need camera access'));

    final ar = File(paths.stringsFile('ar')).readAsStringSync();
    expect(ar, startsWith(stringsFileHeader));
    expect(ar, contains('نحتاج إلى صلاحية الكاميرا'));

    final plist = File(paths.infoPlist).readAsStringSync();
    expect(plist, contains('<key>NSLocationWhenInUseUsageDescription</key>'));
    expect(plist,
        contains('<key>CFBundleDisplayName</key>\n\t<string>My App</string>'));

    final pbx = File(paths.pbxproj).readAsStringSync();
    expect(pbx, contains('path = ar.lproj/InfoPlist.strings;'));

    final backups = snapshot().keys.where((k) => k.endsWith('.bak'));
    expect(backups, isEmpty);
  });

  test('second run is a no-op and validate reports in sync', () {
    runner().run();
    final before = snapshot();
    final second = runner().run();
    expect(second.upToDate, isTrue);
    expect(snapshot(), before);
    expect(runner().validate().inSync, isTrue);
  });

  test('validate reports drift without writing', () {
    final before = snapshot();
    final report = runner().validate();
    expect(report.inSync, isFalse);
    expect(
        report.issues.keys, contains('ios/Runner/ar.lproj/InfoPlist.strings'));
    expect(report.issues['ios/Runner/ar.lproj/InfoPlist.strings']!.first,
        'File is missing');
    expect(snapshot(), before);
  });

  test('dry run computes changes but never writes', () {
    final before = snapshot();
    final report = runner().run(dryRun: true);
    expect(report.changes, hasLength(4));
    expect(snapshot(), before);
    expect(output.toString(), contains('No files were modified'));
  });

  test('skip_pbxproj leaves project.pbxproj untouched', () {
    final original = File(paths.pbxproj).readAsBytesSync();
    final report = runner().run(forceSkipPbxproj: true);
    expect(report.changes, hasLength(3));
    expect(File(paths.pbxproj).readAsBytesSync(), original);
  });

  test('aborts before writing anything when a native file is invalid', () {
    File(paths.pbxproj).writeAsStringSync(
      flutterPbxproj.replaceFirst('rootObject =', 'brokenObject ='),
    );
    final before = snapshot();
    expect(
      () => runner().run(),
      throwsA(isA<LocalizerParseException>()),
    );
    expect(snapshot(), before);
  });

  test('aborts before writing anything when a strings file is malformed', () {
    File(paths.stringsFile('en'))
        .writeAsStringSync('"CFBundleDisplayName" = "My App"\n');
    final before = snapshot();
    expect(() => runner().run(), throwsA(isA<LocalizerParseException>()));
    expect(snapshot(), before);
  });

  test('--backup keeps .bak files and --restore brings the originals back', () {
    final originalPlist = File(paths.infoPlist).readAsBytesSync();
    final originalPbx = File(paths.pbxproj).readAsBytesSync();
    final originalEn = File(paths.stringsFile('en')).readAsBytesSync();

    runner().run(forceBackup: true);
    expect(File('${paths.infoPlist}.bak').readAsBytesSync(), originalPlist);
    expect(File('${paths.pbxproj}.bak').readAsBytesSync(), originalPbx);
    expect(
        File('${paths.stringsFile('en')}.bak').readAsBytesSync(), originalEn);
    expect(File('${paths.stringsFile('ar')}.bak').existsSync(), isFalse);

    final restored = runner().restore();
    expect(restored.files, hasLength(3));
    expect(File(paths.infoPlist).readAsBytesSync(), originalPlist);
    expect(File(paths.pbxproj).readAsBytesSync(), originalPbx);
    expect(File(paths.stringsFile('en')).readAsBytesSync(), originalEn);
    expect(File('${paths.infoPlist}.bak').readAsBytesSync(), originalPlist);
  });

  test('restore fails clearly when there are no backups', () {
    expect(
      () => runner().restore(),
      throwsA(
        isA<LocalizerFileException>()
            .having((e) => e.exitCode, 'exitCode', LocalizerExitCode.noInput),
      ),
    );
  });

  test('missing ios directory is reported', () {
    Directory(paths.iosDir).deleteSync(recursive: true);
    expect(
      () => runner().run(),
      throwsA(isA<LocalizerFileException>()),
    );
  });
}
