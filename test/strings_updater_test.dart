import 'package:ios_privacy_localizer/ios_privacy_localizer.dart';
import 'package:test/test.dart';

import 'fixtures/fixtures.dart';

void main() {
  const updater = StringsUpdater();
  const validator = PlistValidator(useNativeTools: false);

  group('app_name_localizer compatibility', () {
    test('preserves CFBundleDisplayName and CFBundleName', () {
      final result = updater.update(
        appNameLocalizerStrings,
        <String, String>{'NSCameraUsageDescription': 'Camera please'},
      );

      expect(result.changes, <String>['Add "NSCameraUsageDescription"']);
      expect(
        result.content,
        '$stringsFileHeader\n'
        '"CFBundleDisplayName" = "My App";\n'
        '"CFBundleName" = "My App";\n'
        '"NSCameraUsageDescription" = "Camera please";\n',
      );

      final map = StringsParser.parse(result.content).toMap();
      expect(map['CFBundleDisplayName'], 'My App');
      expect(map['CFBundleName'], 'My App');
      expect(map['NSCameraUsageDescription'], 'Camera please');
    });

    test('keeps existing entries verbatim, even with unusual spacing', () {
      const existing = '"CFBundleDisplayName"="تطبيقي";\n'
          '"CFBundleName"   =   "My App"  ;\n';
      final result = updater.update(
        existing,
        <String, String>{'NSCameraUsageDescription': 'x'},
      );
      expect(result.content, contains('"CFBundleDisplayName"="تطبيقي";'));
      expect(result.content, contains('"CFBundleName"   =   "My App"  ;'));
    });

    test('never removes keys that are not configured', () {
      const existing = '"CFBundleDisplayName" = "App";\n'
          '"NSMicrophoneUsageDescription" = "Old mic text";\n';
      final result = updater.update(
        existing,
        <String, String>{'NSCameraUsageDescription': 'Camera'},
      );
      final map = StringsParser.parse(result.content).toMap();
      expect(map.keys, <String>[
        'CFBundleDisplayName',
        'NSMicrophoneUsageDescription',
        'NSCameraUsageDescription',
      ]);
    });

    test('preserves comments and blank-line grouping', () {
      const existing = '/* App name (app_name_localizer) */\n'
          '"CFBundleDisplayName" = "App";\n'
          '\n'
          '// Permissions\n'
          '"NSCameraUsageDescription" = "Old";\n';
      final result = updater.update(
        existing,
        <String, String>{'NSCameraUsageDescription': 'New'},
      );
      expect(
        result.content,
        '$stringsFileHeader\n'
        '/* App name (app_name_localizer) */\n'
        '"CFBundleDisplayName" = "App";\n'
        '\n'
        '// Permissions\n'
        '"NSCameraUsageDescription" = "New";\n',
      );
      expect(result.changes, <String>['Update "NSCameraUsageDescription"']);
    });
  });

  group('merging', () {
    test('creates a new file with the header', () {
      final result = updater.update(null, <String, String>{
        'NSCameraUsageDescription': 'Camera',
        'NSPhotoLibraryUsageDescription': 'Photos',
      });
      expect(
        result.content,
        '$stringsFileHeader\n'
        '"NSCameraUsageDescription" = "Camera";\n'
        '"NSPhotoLibraryUsageDescription" = "Photos";\n',
      );
      expect(result.changes, hasLength(2));
    });

    test('is idempotent', () {
      final translations = <String, String>{
        'NSCameraUsageDescription': 'نحتاج إلى صلاحية الكاميرا',
        'NSLocationWhenInUseUsageDescription': 'Location "nearby"\nbranches',
      };
      final first = updater.update(appNameLocalizerStrings, translations);
      final second = updater.update(first.content, translations);
      expect(second.hasChanges, isFalse);
      expect(second.content, first.content);
    });

    test('does not duplicate the header', () {
      final first = updater.update(
        null,
        <String, String>{'NSCameraUsageDescription': 'A'},
      );
      final second = updater.update(
        first.content,
        <String, String>{'NSCameraUsageDescription': 'B'},
      );
      expect(stringsFileHeader.allMatches(second.content), hasLength(1));
      expect(second.content, startsWith(stringsFileHeader));
    });

    test('updates duplicated keys everywhere', () {
      const existing = '"NSCameraUsageDescription" = "one";\n'
          '"NSCameraUsageDescription" = "two";\n';
      final result = updater.update(
        existing,
        <String, String>{'NSCameraUsageDescription': 'three'},
      );
      expect('"three"'.allMatches(result.content), hasLength(2));
    });

    test('keeps CRLF line endings', () {
      const existing = '"CFBundleDisplayName" = "App";\r\n';
      final result = updater.update(
        existing,
        <String, String>{'NSCameraUsageDescription': 'Camera'},
      );
      expect(result.content, contains('\r\n"NSCameraUsageDescription"'));
      expect(result.content.replaceAll('\r\n', ''), isNot(contains('\n')));
    });

    test('normalizes unquoted keys and multi-line entries', () {
      const existing = 'CFBundleName = "App";\n'
          '"CFBundleDisplayName" =\n    "Display";\n';
      final result = updater.update(
        existing,
        <String, String>{'NSCameraUsageDescription': 'Camera'},
      );
      expect(result.content, contains('"CFBundleName" = "App";'));
      expect(result.content, contains('"CFBundleDisplayName" = "Display";'));
      expect(validator.validateContent(result.content, PlistFileKind.strings),
          isEmpty);
    });

    test('output always passes the .strings validator', () {
      final result = updater.update(appNameLocalizerStrings, <String, String>{
        'NSCameraUsageDescription': r'Quotes " backslash \ newline' '\n' 'end',
        'NSMicrophoneUsageDescription': 'تسجيل الصوت',
      });
      expect(
        validator.validateContent(result.content, PlistFileKind.strings),
        isEmpty,
      );
    });

    test('refuses to manage non-permission keys', () {
      expect(
        () =>
            updater.update(null, <String, String>{'CFBundleDisplayName': 'x'}),
        throwsArgumentError,
      );
    });

    test('throws a parse error and never guesses on malformed input', () {
      expect(
        () => updater.update(
          '"CFBundleDisplayName" = "App"\n"Other" = "x";\n',
          <String, String>{'NSCameraUsageDescription': 'x'},
        ),
        throwsA(
          isA<LocalizerParseException>()
              .having((e) => e.message, 'message', contains('line 2')),
        ),
      );
      expect(
        () => updater.update(
          '/* unterminated',
          <String, String>{'NSCameraUsageDescription': 'x'},
        ),
        throwsA(isA<LocalizerParseException>()),
      );
    });

    test('ignores a byte-order mark', () {
      final result = updater.update(
        '﻿"CFBundleDisplayName" = "App";\n',
        <String, String>{'NSCameraUsageDescription': 'x'},
      );
      expect(result.content, startsWith(stringsFileHeader));
      expect(result.content, contains('"CFBundleDisplayName" = "App";'));
    });
  });

  group('escaping', () {
    test('escapeStringsValue follows the .strings rules', () {
      expect(
        escapeStringsValue('a\\b"c\nd\re'),
        r'a\\b\"c\nde',
      );
    });

    test('unescapeStringsValue is the inverse', () {
      const original = 'Line 1\nSay "hi" \\ done';
      expect(unescapeStringsValue(escapeStringsValue(original)), original);
      expect(unescapeStringsValue(r'\U00e9té'), 'été');
    });

    test('equivalent escapes are not reported as changes', () {
      const existing = r'"NSCameraUsageDescription" = "\U0041BC";' '\n';
      final result = updater.update(
        existing,
        <String, String>{'NSCameraUsageDescription': 'ABC'},
      );
      expect(result.hasChanges, isFalse);
      expect(result.content, existing);
    });
  });
}
