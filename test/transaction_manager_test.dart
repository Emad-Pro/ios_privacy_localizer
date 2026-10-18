import 'dart:convert';
import 'dart:io';

import 'package:ios_privacy_localizer/ios_privacy_localizer.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'fixtures/fixtures.dart';

/// A validator that rejects every file, to force an automatic rollback.
class _RejectingValidator extends PlistValidator {
  const _RejectingValidator() : super(useNativeTools: false);

  @override
  FileValidationResult validateFile(String path, {PlistFileKind? kind}) =>
      FileValidationResult(
        path: path,
        kind: kind,
        errors: const <String>['rejected by test'],
        checks: const <String>['test'],
      );
}

void main() {
  late Directory temp;
  late String plistPath;
  late List<int> originalBytes;
  const validator = PlistValidator(useNativeTools: false);

  setUp(() {
    temp = Directory.systemTemp.createTempSync('ipl_tx_');
    plistPath = p.join(temp.path, 'Info.plist');
    File(plistPath).writeAsStringSync(flutterInfoPlist);
    originalBytes = File(plistPath).readAsBytesSync();
  });

  tearDown(() {
    if (temp.existsSync()) {
      temp.deleteSync(recursive: true);
    }
  });

  List<String> listAll() => temp
      .listSync(recursive: true)
      .map((e) => p.relative(e.path, from: temp.path).replaceAll(r'\', '/'))
      .toList()
    ..sort();

  String modifiedPlist() => const InfoPlistUpdater().update(
        flutterInfoPlist,
        const <String, String>{'NSCameraUsageDescription': 'Camera'},
      ).content;

  test('backupFile snapshots the original and writes a .bak file', () {
    final tx = TransactionManager(validator: validator)..backupFile(plistPath);
    final backup = File('$plistPath.bak');
    expect(backup.existsSync(), isTrue);
    expect(backup.readAsBytesSync(), originalBytes);
    tx.rollback();
  });

  test('commit writes the new content and removes .bak files', () {
    final tx = TransactionManager(validator: validator)
      ..writeString(plistPath, modifiedPlist());
    expect(File('$plistPath.bak').existsSync(), isTrue);

    final report = tx.commit();
    expect(report.isValid, isTrue);
    expect(tx.state, TransactionState.committed);
    expect(File(plistPath).readAsStringSync(), modifiedPlist());
    expect(listAll(), <String>['Info.plist']);
  });

  test('commit(keepBackupFiles: true) retains the .bak files', () {
    TransactionManager(validator: validator)
      ..writeString(plistPath, modifiedPlist())
      ..commit(keepBackupFiles: true);
    expect(File('$plistPath.bak').readAsBytesSync(), originalBytes);
  });

  test('rollback restores exact bytes and deletes new files and folders', () {
    final newFile =
        p.join(temp.path, 'ar.lproj', 'nested', 'InfoPlist.strings');
    final tx = TransactionManager(validator: validator)
      ..writeString(plistPath, modifiedPlist())
      ..writeString(newFile, '"NSCameraUsageDescription" = "x";\n');
    expect(File(newFile).existsSync(), isTrue);

    tx.rollback();

    expect(tx.state, TransactionState.rolledBack);
    expect(File(plistPath).readAsBytesSync(), originalBytes);
    expect(listAll(), <String>['Info.plist']);
  });

  test('a failed validation triggers an automatic rollback', () {
    final stringsPath = p.join(temp.path, 'en.lproj', 'InfoPlist.strings');
    final tx = TransactionManager(validator: validator)
      ..writeString(plistPath, '<plist><dict><key>Broken</key></dict></plist>')
      ..writeString(stringsPath, '"NSCameraUsageDescription" = "ok";\n');

    expect(
      tx.commit,
      throwsA(
        isA<LocalizerValidationException>().having(
          (e) => e.details.join('\n'),
          'details',
          contains('has no value'),
        ),
      ),
    );
    expect(tx.state, TransactionState.rolledBack);
    expect(File(plistPath).readAsBytesSync(), originalBytes);
    expect(listAll(), <String>['Info.plist']);
  });

  test('a rejecting validator rolls back even valid content', () {
    final tx = TransactionManager(validator: const _RejectingValidator())
      ..writeString(plistPath, modifiedPlist());
    expect(tx.commit, throwsA(isA<LocalizerValidationException>()));
    expect(File(plistPath).readAsBytesSync(), originalBytes);
    expect(File('$plistPath.bak').existsSync(), isFalse);
  });

  test('a pre-existing .bak file is never lost', () {
    final backup = File('$plistPath.bak')..writeAsStringSync('older backup');

    TransactionManager(validator: validator)
      ..writeString(plistPath, modifiedPlist())
      ..commit();
    expect(backup.readAsStringSync(), 'older backup');

    TransactionManager(validator: validator)
      ..writeString(plistPath, flutterInfoPlist)
      ..rollback();
    expect(backup.readAsStringSync(), 'older backup');
  });

  test('the snapshot always keeps the first original content', () {
    final tx = TransactionManager(validator: validator)
      ..writeString(plistPath, modifiedPlist())
      ..writeString(plistPath, '${modifiedPlist()}\n');
    expect(File('$plistPath.bak').readAsBytesSync(), originalBytes);
    tx.rollback();
    expect(File(plistPath).readAsBytesSync(), originalBytes);
  });

  test('preserves UTF-16 encoding of existing files', () {
    final stringsPath = p.join(temp.path, 'InfoPlist.strings');
    File(stringsPath).writeAsBytesSync(
      TextFileCodec.encode(
        '"CFBundleDisplayName" = "تطبيقي";\n',
        TextEncodingKind.utf16le,
      ),
    );
    TransactionManager(validator: validator)
      ..writeString(
        stringsPath,
        '"CFBundleDisplayName" = "تطبيقي";\n"NSCameraUsageDescription" = "x";\n',
      )
      ..commit();

    final bytes = File(stringsPath).readAsBytesSync();
    expect(bytes.take(2), <int>[0xFF, 0xFE]);
    final decoded = TextFileCodec.decode(bytes);
    expect(decoded.encoding, TextEncodingKind.utf16le);
    expect(decoded.text, contains('NSCameraUsageDescription'));
  });

  test('new files are written as UTF-8 without BOM', () {
    final path = p.join(temp.path, 'new.strings');
    TransactionManager(validator: validator)
      ..writeString(path, '"NSCameraUsageDescription" = "كاميرا";\n')
      ..commit();
    expect(
      File(path).readAsBytesSync(),
      utf8.encode('"NSCameraUsageDescription" = "كاميرا";\n'),
    );
  });

  test('leaves no temporary files behind', () {
    TransactionManager(validator: validator)
      ..writeString(plistPath, modifiedPlist())
      ..commit();
    expect(listAll().where((name) => name.contains('.tmp')), isEmpty);
  });

  test('registerNewFile refuses existing files', () {
    final tx = TransactionManager(validator: validator);
    expect(() => tx.registerNewFile(plistPath), throwsArgumentError);
    tx.rollback();
    expect(File(plistPath).readAsBytesSync(), originalBytes);
  });

  test('a closed transaction rejects further writes', () {
    final tx = TransactionManager(validator: validator)..commit();
    expect(() => tx.writeString(plistPath, 'x'), throwsStateError);
    expect(tx.rollback, returnsNormally);
    expect(File(plistPath).readAsBytesSync(), originalBytes);
  });
}
