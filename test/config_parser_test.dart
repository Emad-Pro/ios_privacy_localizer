import 'dart:io';

import 'package:ios_privacy_localizer/ios_privacy_localizer.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'fixtures/fixtures.dart';

LocalizerConfig _parse(String yaml, {bool fromPubspec = false}) =>
    ConfigParser.parseString(yaml, fromPubspec: fromPubspec);

Matcher _configError(String fragment) => throwsA(
      isA<LocalizerConfigException>().having(
        (e) => '${e.message} ${e.hint ?? ''}',
        'message',
        contains(fragment),
      ),
    );

void main() {
  test('parses the documented example', () {
    final config = _parse(sampleConfigYaml);
    expect(config.defaultLocale, 'en');
    expect(config.backup, isFalse);
    expect(config.skipPbxproj, isFalse);
    expect(config.locales, <String>['en', 'ar']);
    expect(config.warnings, isEmpty);
    expect(config.permissions.map((e) => e.plistKey), <String>[
      'NSCameraUsageDescription',
      'NSPhotoLibraryUsageDescription',
      'NSLocationWhenInUseUsageDescription',
    ]);
    expect(
      config.infoPlistValues['NSCameraUsageDescription'],
      startsWith('We need camera access'),
    );
    expect(
      config.translationsForLocale('ar')['NSPhotoLibraryUsageDescription'],
      'نحتاج إلى الوصول لمعرض الصور لإرفاق الإيصالات.',
    );
  });

  test('accepts an unwrapped dedicated file', () {
    final config = _parse('''
default_locale: en
permissions:
  camera:
    en: "Camera"
''');
    expect(config.permissions.single.plistKey, 'NSCameraUsageDescription');
  });

  test('requires the section in pubspec.yaml', () {
    expect(
      () => _parse('name: my_app\n', fromPubspec: true),
      _configError('No `ios_privacy_localizer:` section'),
    );
  });

  test('rejects an empty permissions map', () {
    expect(
      () => _parse('ios_privacy_localizer:\n  permissions: {}\n'),
      _configError('is empty'),
    );
    expect(
      () => _parse('ios_privacy_localizer:\n  default_locale: en\n'),
      _configError('missing'),
    );
  });

  test('rejects a permission without translations', () {
    expect(
      () => _parse('ios_privacy_localizer:\n  permissions:\n    camera: {}\n'),
      _configError('at least one locale'),
    );
  });

  test('rejects empty and whitespace-only translations', () {
    expect(
      () => _parse('''
ios_privacy_localizer:
  permissions:
    camera:
      en: "   "
'''),
      _configError('is empty'),
    );
  });

  test('rejects non-string translations', () {
    expect(
      () => _parse('''
ios_privacy_localizer:
  permissions:
    camera:
      en: 42
'''),
      _configError('must be a string'),
    );
  });

  test('validates and normalizes locale codes', () {
    final config = _parse('''
ios_privacy_localizer:
  default_locale: en_US
  permissions:
    camera:
      en_US: "Camera"
      zh-Hans: "相机"
      pt-BR: "Câmera"
''');
    expect(config.locales, <String>['en-US', 'zh-Hans', 'pt-BR']);
    expect(config.defaultLocale, 'en-US');

    expect(
      () => _parse('''
ios_privacy_localizer:
  permissions:
    camera:
      english: "Camera"
'''),
      _configError('Invalid locale code "english"'),
    );
  });

  test('rejects duplicate locales after normalization', () {
    expect(
      () => _parse('''
ios_privacy_localizer:
  permissions:
    camera:
      en_US: "A"
      en-US: "B"
'''),
      _configError('more than once'),
    );
  });

  test('rejects two keys resolving to the same Apple key', () {
    expect(
      () => _parse('''
ios_privacy_localizer:
  permissions:
    camera:
      en: "A"
    NSCameraUsageDescription:
      en: "B"
'''),
      _configError('both resolve to NSCameraUsageDescription'),
    );
  });

  test('reports unknown permissions with a suggestion and line number', () {
    expect(
      () => _parse('''
ios_privacy_localizer:
  permissions:
    camra:
      en: "A"
'''),
      throwsA(
        isA<LocalizerConfigException>()
            .having((e) => e.message, 'message', contains('line 3'))
            .having((e) => e.hint, 'hint', contains('"camera"')),
      ),
    );
  });

  test('falls back per permission when default_locale is missing', () {
    final config = _parse('''
ios_privacy_localizer:
  default_locale: en
  permissions:
    camera:
      en: "Camera"
      ar: "كاميرا"
    microphone:
      ar: "ميكروفون"
''');
    expect(config.defaultLocale, 'en');
    expect(config.infoPlistValues['NSMicrophoneUsageDescription'], 'ميكروفون');
    expect(config.warnings.single, contains('"microphone" has no "en"'));
  });

  test('falls back to the first locale when default_locale is unused', () {
    final config = _parse('''
ios_privacy_localizer:
  default_locale: fr
  permissions:
    camera:
      ar: "كاميرا"
      en: "Camera"
''');
    expect(config.defaultLocale, 'ar');
    expect(config.warnings.single, contains('falling back to "ar"'));
  });

  test('infers default_locale with a warning when omitted', () {
    final config = _parse('''
ios_privacy_localizer:
  permissions:
    camera:
      en: "Camera"
''');
    expect(config.defaultLocale, 'en');
    expect(config.warnings.single, contains('`default_locale` is not set'));
  });

  test('validates boolean options and warns on unknown options', () {
    expect(
      () => _parse('''
ios_privacy_localizer:
  backup: yes please
  permissions:
    camera:
      en: "Camera"
'''),
      _configError('`backup` must be true or false'),
    );
    final config = _parse('''
ios_privacy_localizer:
  backup: true
  skip_pbxproj: true
  colour: blue
  default_locale: en
  permissions:
    camera:
      en: "Camera"
''');
    expect(config.backup, isTrue);
    expect(config.skipPbxproj, isTrue);
    expect(config.warnings.single, contains('Unknown option "colour"'));
  });

  test('reports YAML syntax errors', () {
    expect(
      () => _parse('ios_privacy_localizer:\n  permissions: [\n'),
      throwsA(isA<LocalizerConfigException>()),
    );
  });

  group('load()', () {
    late Directory temp;

    setUp(() => temp = Directory.systemTemp.createTempSync('ipl_cfg_'));
    tearDown(() => temp.deleteSync(recursive: true));

    test('prefers ios_privacy_localizer.yaml over pubspec.yaml', () {
      File(p.join(temp.path, 'pubspec.yaml')).writeAsStringSync(
        'name: app\nios_privacy_localizer:\n  permissions:\n    camera:\n      en: "From pubspec"\n',
      );
      File(p.join(temp.path, 'ios_privacy_localizer.yaml')).writeAsStringSync(
        'ios_privacy_localizer:\n  default_locale: en\n  permissions:\n    camera:\n      en: "From dedicated"\n',
      );
      final config = ConfigParser(projectRoot: temp.path).load();
      expect(config.infoPlistValues.values.single, 'From dedicated');
    });

    test('reads the pubspec.yaml section', () {
      File(p.join(temp.path, 'pubspec.yaml')).writeAsStringSync(
        'name: app\nios_privacy_localizer:\n  default_locale: en\n  permissions:\n    camera:\n      en: "From pubspec"\n',
      );
      final config = ConfigParser(projectRoot: temp.path).load();
      expect(config.infoPlistValues.values.single, 'From pubspec');
    });

    test('supports --config relative to the project root', () {
      File(p.join(temp.path, 'custom.yaml'))
          .writeAsStringSync(sampleConfigYaml);
      final config =
          ConfigParser(projectRoot: temp.path, configPath: 'custom.yaml')
              .load();
      expect(config.permissions, hasLength(3));
    });

    test('fails clearly when nothing is configured', () {
      expect(
        () => ConfigParser(projectRoot: temp.path).load(),
        throwsA(
          isA<LocalizerFileException>()
              .having((e) => e.exitCode, 'exitCode', LocalizerExitCode.noInput),
        ),
      );
      expect(
        () => ConfigParser(projectRoot: temp.path, configPath: 'missing.yaml')
            .load(),
        throwsA(isA<LocalizerFileException>()),
      );
    });
  });
}
