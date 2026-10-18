import 'package:ios_privacy_localizer/ios_privacy_localizer.dart';
import 'package:test/test.dart';

import 'fixtures/fixtures.dart';

int _count(String haystack, String needle) =>
    needle.allMatches(haystack).length;

void main() {
  const updater = PbxprojUpdater();
  const validator = PlistValidator(useNativeTools: false);
  final vg = PbxprojUpdater.variantGroupId;
  final bf = PbxprojUpdater.buildFileId;
  final en = PbxprojUpdater.fileRefId('en');
  final ar = PbxprojUpdater.fileRefId('ar');

  group('deterministic IDs', () {
    test('are stable 24-char uppercase hex strings', () {
      for (final id in <String>[vg, bf, en, ar]) {
        expect(id, matches(RegExp(r'^[0-9A-F]{24}$')));
      }
      expect(
        generateDeterministicId('PBXVariantGroup:InfoPlist.strings'),
        vg,
      );
      expect(<String>{vg, bf, en, ar}, hasLength(4));
    });
  });

  group('fresh Flutter project', () {
    late FileUpdateResult result;

    setUp(() {
      result = updater.update(flutterPbxproj, const <String>['en', 'ar']);
    });

    test('Step A: adds one PBXFileReference per locale', () {
      expect(
        result.content,
        contains('\t\t$ar /* ar */ = {isa = PBXFileReference; '
            'lastKnownFileType = text.plist.strings; name = ar; '
            'path = ar.lproj/InfoPlist.strings; sourceTree = "<group>"; };\n'),
      );
      expect(result.content,
          contains('\t\t$en /* en */ = {isa = PBXFileReference;'));
    });

    test('Step B: creates the InfoPlist.strings variant group', () {
      expect(
        result.content,
        contains('\t\t$vg /* InfoPlist.strings */ = {\n'
            '\t\t\tisa = PBXVariantGroup;\n'
            '\t\t\tchildren = (\n'
            '\t\t\t\t$en /* en */,\n'
            '\t\t\t\t$ar /* ar */,\n'
            '\t\t\t);\n'
            '\t\t\tname = InfoPlist.strings;\n'
            '\t\t\tsourceTree = "<group>";\n'
            '\t\t};\n'),
      );
      final begin =
          result.content.indexOf('/* Begin PBXVariantGroup section */');
      final end = result.content.indexOf('/* End PBXVariantGroup section */');
      final at = result.content.indexOf('$vg /* InfoPlist.strings */ = {');
      expect(at, greaterThan(begin));
      expect(at, lessThan(end));
    });

    test('Step C: attaches the variant group to the Runner group', () {
      expect(
        result.content,
        contains(
            '\t\t\t\t74858FAD1ED2DC5600515810 /* Runner-Bridging-Header.h */,\n'
            '\t\t\t\t$vg /* InfoPlist.strings */,\n'
            '\t\t\t);\n'
            '\t\t\tpath = Runner;'),
      );
    });

    test('Step D: adds the PBXBuildFile and the Resources phase entry', () {
      expect(
        result.content,
        contains('\t\t$bf /* InfoPlist.strings in Resources */ = '
            '{isa = PBXBuildFile; fileRef = $vg /* InfoPlist.strings */; };\n'),
      );
      expect(
        result.content,
        contains(
            '\t\t\t\t97C146FC1CF9000F007C117D /* Main.storyboard in Resources */,\n'
            '\t\t\t\t$bf /* InfoPlist.strings in Resources */,\n'),
      );
    });

    test('Step E: adds locales to knownRegions, keeping en and Base', () {
      expect(
        result.content,
        contains('knownRegions = (\n'
            '\t\t\t\ten,\n'
            '\t\t\t\tBase,\n'
            '\t\t\t\tar,\n'
            '\t\t\t);'),
      );
    });

    test('never removes or rewrites an existing line', () {
      expect(
        isOrderedSubsequence(
          flutterPbxproj.split('\n'),
          result.content.split('\n'),
        ),
        isTrue,
      );
    });

    test('the result passes the structural validator', () {
      expect(
        validator.validateContent(result.content, PlistFileKind.pbxproj),
        isEmpty,
      );
    });

    test('is idempotent', () {
      final second = updater.update(result.content, const <String>['en', 'ar']);
      expect(second.hasChanges, isFalse);
      expect(second.content, result.content);
    });

    test('adding a locale later only adds what is missing', () {
      final second =
          updater.update(result.content, const <String>['en', 'ar', 'fr']);
      final fr = PbxprojUpdater.fileRefId('fr');
      expect(second.changes, <String>[
        'Add PBXFileReference for fr.lproj/InfoPlist.strings ($fr)',
        'Add "fr" to the InfoPlist.strings variant group',
        'Add "fr" to knownRegions',
      ]);
      expect(_count(second.content, 'isa = PBXVariantGroup;'), 3);
      expect(_count(second.content, '/* InfoPlist.strings in Resources */ = {'),
          1);
    });
  });

  test('quotes locales that contain a hyphen', () {
    final result =
        updater.update(flutterPbxproj, const <String>['pt-BR', 'zh-Hans']);
    expect(
      result.content,
      contains('name = "pt-BR"; path = "pt-BR.lproj/InfoPlist.strings";'),
    );
    expect(
      result.content,
      contains('name = "zh-Hans"; path = "zh-Hans.lproj/InfoPlist.strings";'),
    );
    expect(result.content, contains('\t\t\t\t"zh-Hans",\n'));
    expect(
      validator.validateContent(result.content, PlistFileKind.pbxproj),
      isEmpty,
    );
    expect(
      updater.update(
          result.content, const <String>['pt-BR', 'zh-Hans']).hasChanges,
      isFalse,
    );
  });

  group('existing InfoPlist.strings variant group (app_name_localizer)', () {
    late FileUpdateResult result;

    setUp(() {
      result = updater.update(
        pbxprojWithExistingStrings,
        const <String>['en', 'ar'],
      );
    });

    test('reuses the existing group instead of creating a duplicate', () {
      expect(result.content, isNot(contains(vg)));
      expect(_count(result.content, 'name = InfoPlist.strings;'), 1);
      expect(
        result.content,
        contains('\t\t$existingVariantGroupId /* InfoPlist.strings */ = {\n'
            '\t\t\tisa = PBXVariantGroup;\n'
            '\t\t\tchildren = (\n'
            '\t\t\t\t$existingEnFileRefId /* en */,\n'
            '\t\t\t\t$ar /* ar */,\n'
            '\t\t\t);'),
      );
    });

    test('does not duplicate the existing en reference or build file', () {
      expect(result.content, isNot(contains(en)));
      expect(result.content, isNot(contains(bf)));
      expect(
        _count(result.content, 'InfoPlist.strings in Resources */,'),
        1,
      );
      expect(result.changes, <String>[
        'Add PBXFileReference for ar.lproj/InfoPlist.strings ($ar)',
        'Add "ar" to the InfoPlist.strings variant group',
        'Add "ar" to knownRegions',
      ]);
    });

    test('is idempotent', () {
      final second = updater.update(result.content, const <String>['en', 'ar']);
      expect(second.hasChanges, isFalse);
    });
  });

  test('creates the PBXVariantGroup section when it is missing', () {
    final start = flutterPbxproj.indexOf('/* Begin PBXVariantGroup section */');
    final endMarker = '/* End PBXVariantGroup section */\n\n';
    final end = flutterPbxproj.indexOf(endMarker) + endMarker.length;
    final withoutSection = flutterPbxproj
        .replaceRange(start, end, '')
        .replaceAll(
            '\t\t\t\t97C146FA1CF9000F007C117D /* Main.storyboard */,\n', '')
        .replaceAll(
            '\t\t\t\t97C146FF1CF9000F007C117D /* LaunchScreen.storyboard */,\n',
            '');
    expect(withoutSection, isNot(contains('PBXVariantGroup')));

    final result = updater.update(withoutSection, const <String>['en']);
    final begin = result.content.indexOf('/* Begin PBXVariantGroup section */');
    final finish = result.content.indexOf('/* End PBXVariantGroup section */');
    final config =
        result.content.indexOf('/* Begin XCBuildConfiguration section */');
    expect(begin, greaterThan(0));
    expect(finish, greaterThan(begin));
    expect(config, greaterThan(finish));
    expect(
      result.content.substring(begin, finish),
      contains('$vg /* InfoPlist.strings */ = {'),
    );
    expect(
      validator.validateContent(result.content, PlistFileKind.pbxproj),
      isEmpty,
    );
  });

  test('is not confused by brackets inside quoted strings', () {
    final tricky = flutterPbxproj.replaceFirst(
      r'xcode_backend.sh\" build";',
      r'xcode_backend.sh\" build\ncase $X in a) echo \"{ ( [\" ;; esac\n";',
    );
    expect(validator.validateContent(tricky, PlistFileKind.pbxproj), isEmpty);
    final result = updater.update(tricky, const <String>['ar']);
    expect(result.content, contains(r'case $X in a) echo \"{ ( [\" ;; esac'));
    expect(
      validator.validateContent(result.content, PlistFileKind.pbxproj),
      isEmpty,
    );
  });

  test('keeps CRLF line endings', () {
    final crlf = flutterPbxproj.replaceAll('\n', '\r\n');
    final result = updater.update(crlf, const <String>['ar']);
    expect(result.content.replaceAll('\r\n', ''), isNot(contains('\n')));
    expect(updater.update(result.content, const <String>['ar']).hasChanges,
        isFalse);
  });

  test('does not hijack an InfoPlist.strings group of another target', () {
    // Simulate an app extension group that owns its own InfoPlist.strings.
    final withExtension = pbxprojWithExistingStrings
        .replaceFirst(
          '\t\t\t\t$existingVariantGroupId /* InfoPlist.strings */,\n',
          '',
        )
        .replaceFirst(
          '\t\t\t\t$existingBuildFileId /* InfoPlist.strings in Resources */,\n',
          '',
        )
        .replaceFirst(
          '/* End PBXGroup section */',
          '\t\tBBBB00000000000000000001 /* NotificationService */ = {\n'
              '\t\t\tisa = PBXGroup;\n'
              '\t\t\tchildren = (\n'
              '\t\t\t\t$existingVariantGroupId /* InfoPlist.strings */,\n'
              '\t\t\t);\n'
              '\t\t\tpath = NotificationService;\n'
              '\t\t\tsourceTree = "<group>";\n'
              '\t\t};\n'
              '/* End PBXGroup section */',
        );
    final result = updater.update(withExtension, const <String>['en']);
    expect(result.content, contains('$vg /* InfoPlist.strings */ = {'));
    expect(
      result.content,
      contains('\t\t\t\t$existingEnFileRefId /* en */,\n\t\t\t);'),
    );
  });

  test('fails safely when the Runner group cannot be found', () {
    final broken = flutterPbxproj.replaceFirst('path = Runner;', 'path = App;');
    expect(
      () => updater.update(broken, const <String>['ar']),
      throwsA(isA<LocalizerPbxprojException>()),
    );
  });

  test('fails safely on a malformed file', () {
    final broken =
        flutterPbxproj.replaceFirst('isa = PBXGroup;', 'isa = PBXGroup');
    expect(
      () => updater.update(broken, const <String>['ar']),
      throwsA(isA<LocalizerParseException>()),
    );
  });

  test('quote follows Xcode rules', () {
    expect(PbxprojUpdater.quote('ar'), 'ar');
    expect(PbxprojUpdater.quote('ar.lproj/InfoPlist.strings'),
        'ar.lproj/InfoPlist.strings');
    expect(PbxprojUpdater.quote('zh-Hans'), '"zh-Hans"');
    expect(PbxprojUpdater.quote('<group>'), '"<group>"');
    expect(PbxprojUpdater.quote(''), '""');
  });
}
