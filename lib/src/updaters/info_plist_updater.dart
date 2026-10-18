import 'package:xml/xml.dart';

import '../exceptions/localizer_exception.dart';
import '../models/localizer_config.dart';

/// Updates the top-level `<dict>` of an XML `Info.plist` through the DOM.
///
/// Only the configured keys (and `CFBundleAllowMixedLocalizations`) are ever
/// touched; every other key, value, comment and whitespace node is kept. When
/// nothing needs to change the original text is returned byte for byte.
class InfoPlistUpdater {
  /// Creates an `Info.plist` updater.
  const InfoPlistUpdater();

  /// Lets iOS resolve localized `.lproj` strings across frameworks.
  static const String mixedLocalizationsKey = 'CFBundleAllowMixedLocalizations';

  /// Inserts or updates every key of [usageDescriptions] with a `<string>`
  /// value and, when [ensureMixedLocalizations] is `true`, sets
  /// `CFBundleAllowMixedLocalizations` to `<true/>`.
  FileUpdateResult update(
    String source,
    Map<String, String> usageDescriptions, {
    bool ensureMixedLocalizations = true,
    String sourceName = 'Info.plist',
  }) {
    final XmlDocument document;
    try {
      document = XmlDocument.parse(source);
    } on XmlException catch (e) {
      throw LocalizerParseException(
        '$sourceName is not valid XML: $e',
        path: sourceName,
        hint: 'If it is a binary plist, convert it first with '
            '`plutil -convert xml1 ios/Runner/Info.plist`.',
      );
    }

    final dict = _mainDict(document, sourceName);
    final eol = source.contains('\r\n') ? '\r\n' : '\n';
    final changes = <String>[];

    usageDescriptions.forEach((key, value) {
      final outcome = _upsert(
        dict,
        key,
        build: () => XmlElement.tag(
          'string',
          children: <XmlNode>[XmlText(value)],
        ),
        isCurrent: (element) =>
            element.name.local == 'string' && element.innerText == value,
        eol: eol,
        sourceName: sourceName,
      );
      if (outcome != null) {
        changes.add('$outcome $key');
      }
    });

    if (ensureMixedLocalizations) {
      final outcome = _upsert(
        dict,
        mixedLocalizationsKey,
        build: () => XmlElement.tag('true'),
        isCurrent: (element) => element.name.local == 'true',
        eol: eol,
        sourceName: sourceName,
      );
      if (outcome != null) {
        changes.add('$outcome $mixedLocalizationsKey = true');
      }
    }

    if (changes.isEmpty) {
      return FileUpdateResult(source, const <String>[]);
    }

    var output = document.toXmlString();
    if (source.endsWith('\n') && !output.endsWith('\n')) {
      output += eol;
    }
    return FileUpdateResult(output, List<String>.unmodifiable(changes));
  }

  static XmlElement _mainDict(XmlDocument document, String sourceName) {
    final roots = document.childElements.toList();
    if (roots.length != 1 || roots.single.name.local != 'plist') {
      throw LocalizerParseException(
        '$sourceName must have a single <plist> root element.',
        path: sourceName,
      );
    }
    final dicts = roots.single.childElements.toList();
    if (dicts.length != 1 || dicts.single.name.local != 'dict') {
      throw LocalizerParseException(
        '$sourceName: <plist> must contain exactly one top-level <dict>.',
        path: sourceName,
      );
    }
    return dicts.single;
  }

  /// Returns `Add`, `Update` or `null` when the value is already correct.
  static String? _upsert(
    XmlElement dict,
    String key, {
    required XmlElement Function() build,
    required bool Function(XmlElement element) isCurrent,
    required String eol,
    required String sourceName,
  }) {
    final elements = dict.childElements.toList();
    var found = false;
    var updated = false;

    for (var i = 0; i < elements.length; i++) {
      final element = elements[i];
      if (element.name.local != 'key' || element.innerText.trim() != key) {
        continue;
      }
      found = true;
      if (i + 1 >= elements.length || elements[i + 1].name.local == 'key') {
        throw LocalizerParseException(
          '$sourceName: <key>$key</key> has no value element.',
          path: sourceName,
        );
      }
      final value = elements[i + 1];
      i++;
      if (isCurrent(value)) {
        continue;
      }
      value.replace(build());
      updated = true;
    }

    if (!found) {
      _appendPair(dict, key, build(), eol);
      return 'Add';
    }
    return updated ? 'Update' : null;
  }

  static void _appendPair(
    XmlElement dict,
    String key,
    XmlElement value,
    String eol,
  ) {
    final indent = _childIndent(dict);
    final keyElement = XmlElement.tag(
      'key',
      children: <XmlNode>[XmlText(key)],
    );
    final nodes = <XmlNode>[
      XmlText('$eol$indent'),
      keyElement,
      XmlText('$eol$indent'),
      value,
    ];

    final children = dict.children;
    final last = children.isEmpty ? null : children.last;
    if (last is XmlText &&
        last.value.trim().isEmpty &&
        last.value.contains('\n')) {
      children.insertAll(children.length - 1, nodes);
    } else {
      children
        ..addAll(nodes)
        ..add(XmlText('$eol${_ownIndent(dict)}'));
    }
  }

  /// The indentation used by the existing children of [dict].
  static String _childIndent(XmlElement dict) {
    for (final node in dict.children) {
      if (node is! XmlElement) {
        continue;
      }
      final previous = node.previousSibling;
      if (previous is XmlText) {
        final text = previous.value;
        final newline = text.lastIndexOf('\n');
        if (newline >= 0) {
          final indent = text.substring(newline + 1);
          if (indent.trim().isEmpty) {
            return indent;
          }
        }
      }
      break;
    }
    return '${_ownIndent(dict)}\t';
  }

  /// The indentation of the line [element] starts on.
  static String _ownIndent(XmlElement element) {
    final previous = element.previousSibling;
    if (previous is XmlText) {
      final text = previous.value;
      final newline = text.lastIndexOf('\n');
      if (newline >= 0) {
        final indent = text.substring(newline + 1);
        if (indent.trim().isEmpty) {
          return indent;
        }
      }
    }
    return '';
  }
}
