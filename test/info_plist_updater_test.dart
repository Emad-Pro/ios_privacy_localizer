import 'package:ios_privacy_localizer/ios_privacy_localizer.dart';
import 'package:test/test.dart';
import 'package:xml/xml.dart';

import 'fixtures/fixtures.dart';

Map<String, String> _topLevelStrings(String plist) {
  final dict = XmlDocument.parse(plist).rootElement.childElements.single;
  final elements = dict.childElements.toList();
  return <String, String>{
    for (var i = 0; i + 1 < elements.length; i += 2)
      elements[i].innerText: elements[i + 1].name.local == 'string'
          ? elements[i + 1].innerText
          : '<${elements[i + 1].name.local}>',
  };
}

void main() {
  const updater = InfoPlistUpdater();
  const validator = PlistValidator(useNativeTools: false);
  const values = <String, String>{
    'NSCameraUsageDescription': 'We need camera access to scan QR codes.',
    'NSPhotoLibraryUsageDescription': 'We need photo access for receipts.',
  };

  test('appends new keys before </dict> keeping every original line', () {
    final result = updater.update(flutterInfoPlist, values);

    expect(result.changes, <String>[
      'Add NSCameraUsageDescription',
      'Add NSPhotoLibraryUsageDescription',
      'Add CFBundleAllowMixedLocalizations = true',
    ]);

    final untouchedPrefix =
        flutterInfoPlist.substring(0, flutterInfoPlist.indexOf('\n</dict>'));
    expect(result.content, startsWith(untouchedPrefix));
    expect(
      result.content.substring(untouchedPrefix.length),
      '\n\t<key>NSCameraUsageDescription</key>'
      '\n\t<string>We need camera access to scan QR codes.</string>'
      '\n\t<key>NSPhotoLibraryUsageDescription</key>'
      '\n\t<string>We need photo access for receipts.</string>'
      '\n\t<key>CFBundleAllowMixedLocalizations</key>'
      '\n\t<true/>'
      '\n</dict>\n</plist>\n',
    );
  });

  test('preserves CFBundleDisplayName, CFBundleName and all other keys', () {
    final before = _topLevelStrings(flutterInfoPlist);
    final after =
        _topLevelStrings(updater.update(flutterInfoPlist, values).content);
    before.forEach((key, value) {
      expect(after[key], value, reason: key);
    });
    expect(after['CFBundleDisplayName'], 'My App');
    expect(after['CFBundleName'], 'my_app');
  });

  test('updates an existing key in place', () {
    final initial = flutterInfoPlist.replaceFirst(
      '\t<key>CFBundleExecutable</key>',
      '\t<key>NSCameraUsageDescription</key>\n'
          '\t<string>Old text</string>\n'
          '\t<key>CFBundleExecutable</key>',
    );
    final result = updater.update(
      initial,
      const <String, String>{'NSCameraUsageDescription': 'New text'},
    );
    expect(result.changes.first, 'Update NSCameraUsageDescription');
    expect(result.content, isNot(contains('Old text')));
    expect(
      result.content,
      contains('\t<key>NSCameraUsageDescription</key>\n'
          '\t<string>New text</string>\n'
          '\t<key>CFBundleExecutable</key>'),
    );
  });

  test('replaces a non-string value with a <string>', () {
    final initial = flutterInfoPlist.replaceFirst(
      '</dict>\n</plist>',
      '\t<key>NSCameraUsageDescription</key>\n\t<false/>\n</dict>\n</plist>',
    );
    final result = updater.update(
      initial,
      const <String, String>{'NSCameraUsageDescription': 'Camera'},
    );
    expect(
        _topLevelStrings(result.content)['NSCameraUsageDescription'], 'Camera');
  });

  test('sets CFBundleAllowMixedLocalizations to true when false', () {
    final initial = flutterInfoPlist.replaceFirst(
      '</dict>\n</plist>',
      '\t<key>CFBundleAllowMixedLocalizations</key>\n\t<false/>\n</dict>\n</plist>',
    );
    final result = updater.update(initial, const <String, String>{});
    expect(result.changes, <String>[
      'Update CFBundleAllowMixedLocalizations = true',
    ]);
    expect(
      result.content,
      contains('<key>CFBundleAllowMixedLocalizations</key>\n\t<true/>'),
    );
  });

  test('is idempotent and returns the original text untouched', () {
    final first = updater.update(flutterInfoPlist, values);
    final second = updater.update(first.content, values);
    expect(second.hasChanges, isFalse);
    expect(second.content, first.content);
  });

  test('escapes XML special characters', () {
    final result = updater.update(
      flutterInfoPlist,
      const <String, String>{'NSCameraUsageDescription': 'Scan <QR> & "codes"'},
    );
    expect(result.content,
        contains('<string>Scan &lt;QR> &amp; "codes"</string>'));
    expect(
      _topLevelStrings(result.content)['NSCameraUsageDescription'],
      'Scan <QR> & "codes"',
    );
  });

  test('writes Arabic text unchanged', () {
    const arabic = 'نحتاج إلى صلاحية الكاميرا لمسح رموز QR';
    final result = updater.update(
      flutterInfoPlist,
      const <String, String>{'NSCameraUsageDescription': arabic},
    );
    expect(result.content, contains('<string>$arabic</string>'));
  });

  test('output passes the structural plist validator', () {
    final result = updater.update(flutterInfoPlist, values);
    expect(
      validator.validateContent(result.content, PlistFileKind.infoPlist),
      isEmpty,
    );
  });

  test('keeps CRLF line endings', () {
    final crlf = flutterInfoPlist.replaceAll('\n', '\r\n');
    final result = updater.update(crlf, values);
    expect(result.content.replaceAll('\r\n', ''), isNot(contains('\n')));
  });

  test('handles an empty <dict/>', () {
    const empty = '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<plist version="1.0">\n<dict/>\n</plist>\n';
    final result = updater.update(
      empty,
      const <String, String>{'NSCameraUsageDescription': 'Camera'},
    );
    expect(
      validator.validateContent(result.content, PlistFileKind.infoPlist),
      isEmpty,
    );
    expect(
        _topLevelStrings(result.content)['NSCameraUsageDescription'], 'Camera');
  });

  test('rejects invalid documents without modifying them', () {
    expect(
      () => updater.update('<plist><dict>', values),
      throwsA(isA<LocalizerParseException>()),
    );
    expect(
      () => updater.update('<plist><array/></plist>', values),
      throwsA(isA<LocalizerParseException>()),
    );
  });
}
