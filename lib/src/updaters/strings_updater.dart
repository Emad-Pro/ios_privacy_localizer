import 'package:meta/meta.dart';

import '../exceptions/localizer_exception.dart';
import '../mapper/permission_mapper.dart';
import '../models/localizer_config.dart';
import '../safety/plist_validator.dart';

/// First line of every `InfoPlist.strings` file managed by this tool.
const String stringsFileHeader =
    '/* Generated & Managed by ios_privacy_localizer - Created by Emad Younis */';

/// Escapes [input] for use inside a double-quoted `.strings` value.
String escapeStringsValue(String input) {
  return input
      .replaceAll(r'\', r'\\')
      .replaceAll('"', r'\"')
      .replaceAll('\n', r'\n')
      .replaceAll('\r', '');
}

/// Decodes the escape sequences of a raw (still escaped) `.strings` value.
String unescapeStringsValue(String raw) {
  if (!raw.contains(r'\')) {
    return raw;
  }
  final out = StringBuffer();
  var i = 0;
  while (i < raw.length) {
    final c = raw[i];
    if (c != r'\' || i + 1 >= raw.length) {
      out.write(c);
      i++;
      continue;
    }
    final next = raw[i + 1];
    switch (next) {
      case 'n':
        out.write('\n');
        i += 2;
      case 't':
        out.write('\t');
        i += 2;
      case 'r':
        out.write('\r');
        i += 2;
      case 'U' || 'u':
        final hex = i + 6 <= raw.length ? raw.substring(i + 2, i + 6) : '';
        final code = int.tryParse(hex, radix: 16);
        if (hex.length == 4 && code != null) {
          out.writeCharCode(code);
          i += 6;
        } else {
          out.write(next);
          i += 2;
        }
      default:
        out.write(next);
        i += 2;
    }
  }
  return out.toString();
}

/// A comment or an entry of a `.strings` file.
@immutable
sealed class StringsItem {
  const StringsItem({required this.blankLineBefore});

  /// Whether an empty line separated this item from the previous one.
  final bool blankLineBefore;
}

/// A `/* ... */` or `// ...` comment, kept verbatim.
final class StringsComment extends StringsItem {
  const StringsComment(this.text, {required super.blankLineBefore});

  /// The comment exactly as written, including its delimiters.
  final String text;
}

/// A `"KEY" = "VALUE";` entry.
final class StringsEntry extends StringsItem {
  const StringsEntry({
    required this.rawKey,
    required this.keyQuoted,
    required this.rawValue,
    required this.valueQuoted,
    required this.sourceText,
    required super.blankLineBefore,
  });

  /// The key as written (escape sequences not decoded, quotes removed).
  final String rawKey;

  /// Whether the key was written in double quotes.
  final bool keyQuoted;

  /// The value as written (escape sequences not decoded, quotes removed).
  final String rawValue;

  /// Whether the value was written in double quotes.
  final bool valueQuoted;

  /// The full original text of the entry, from the key to the `;`.
  final String sourceText;

  /// The decoded key.
  String get key => keyQuoted ? unescapeStringsValue(rawKey) : rawKey;

  /// The decoded value.
  String get value => valueQuoted ? unescapeStringsValue(rawValue) : rawValue;

  /// Whether [sourceText] can be written back unchanged as a canonical,
  /// single-line entry.
  bool get isCanonical =>
      keyQuoted &&
      valueQuoted &&
      !sourceText.contains('\n') &&
      !sourceText.contains('\r') &&
      PlistValidator.stringsLinePattern.hasMatch(sourceText);

  /// The entry as a canonical single line.
  String render() {
    if (isCanonical) {
      return sourceText;
    }
    return '"${_toSingleLine(rawKey)}" = "${_toSingleLine(rawValue)}";';
  }

  static String _toSingleLine(String raw) => raw
      .replaceAll('\r\n', r'\n')
      .replaceAll('\n', r'\n')
      .replaceAll('\r', r'\n');
}

/// The parsed content of a `.strings` file.
@immutable
class StringsDocument {
  StringsDocument(List<StringsItem> items)
      : items = List<StringsItem>.unmodifiable(items);

  /// Comments and entries in file order.
  final List<StringsItem> items;

  /// Only the entries, in file order.
  Iterable<StringsEntry> get entries => items.whereType<StringsEntry>();

  /// Decoded key -> decoded value (the last occurrence wins, as on iOS).
  Map<String, String> toMap() => <String, String>{
        for (final entry in entries) entry.key: entry.value,
      };
}

/// Tolerant parser for `.strings` files (quoted or bare tokens, block and
/// line comments, any whitespace layout, optional byte-order mark).
abstract final class StringsParser {
  /// Parses [source]. Throws a [LocalizerParseException] with line and
  /// column information on malformed input.
  static StringsDocument parse(
    String source, {
    String sourceName = 'InfoPlist.strings',
  }) =>
      _StringsScanner(source, sourceName).scan();
}

/// Non-destructive merger for `<locale>.lproj/InfoPlist.strings`.
///
/// Existing entries (for example `CFBundleDisplayName` and `CFBundleName`
/// written by `app_name_localizer`) and comments are preserved in their
/// original order; only the configured `NS*UsageDescription` keys are
/// updated or appended. Keys are never removed.
class StringsUpdater {
  const StringsUpdater();

  /// Merges [translations] (Apple key -> text) into [existingContent].
  ///
  /// Pass `null` for [existingContent] when the file does not exist yet.
  /// When no value changes, [existingContent] is returned unchanged.
  FileUpdateResult update(
    String? existingContent,
    Map<String, String> translations, {
    String sourceName = 'InfoPlist.strings',
  }) {
    for (final key in translations.keys) {
      if (!PermissionMapper.isRawKey(key)) {
        throw ArgumentError.value(
          key,
          'translations',
          'only NS*UsageDescription keys may be managed',
        );
      }
    }

    final source = existingContent ?? '';
    final eol = source.contains('\r\n') ? '\r\n' : '\n';
    final document = StringsParser.parse(source, sourceName: sourceName);

    final lines = <_Line>[
      for (final item in document.items)
        if (!(item is StringsComment && _isOwnHeader(item.text))) _Line(item),
    ];
    final changes = <String>[];

    translations.forEach((key, value) {
      final escaped = escapeStringsValue(value);
      final wanted = unescapeStringsValue(escaped);
      var found = false;
      var updated = false;
      for (final line in lines) {
        final item = line.item;
        if (item is! StringsEntry || item.key != key) {
          continue;
        }
        found = true;
        final current = line.replacementRaw != null
            ? unescapeStringsValue(line.replacementRaw!)
            : item.value;
        if (current != wanted) {
          line.replacementRaw = escaped;
          updated = true;
        }
      }
      if (!found) {
        lines.add(_Line.added(key, escaped));
        changes.add('Add "$key"');
      } else if (updated) {
        changes.add('Update "$key"');
      }
    });

    if (changes.isEmpty) {
      return FileUpdateResult(source, const <String>[]);
    }

    final out = StringBuffer(stringsFileHeader);
    for (final line in lines) {
      out.write(eol);
      if (line.item.blankLineBefore) {
        out.write(eol);
      }
      out.write(line.render());
    }
    out.write(eol);
    return FileUpdateResult(out.toString(), List<String>.unmodifiable(changes));
  }

  static bool _isOwnHeader(String comment) =>
      comment.trim() == stringsFileHeader ||
      comment.contains('Generated & Managed by ios_privacy_localizer');
}

class _Line {
  _Line(this.item);

  _Line.added(String key, String escapedValue)
      : item = StringsEntry(
          rawKey: escapeStringsValue(key),
          keyQuoted: true,
          rawValue: escapedValue,
          valueQuoted: true,
          sourceText: '"${escapeStringsValue(key)}" = "$escapedValue";',
          blankLineBefore: false,
        );

  final StringsItem item;

  /// New raw (escaped) value, when the entry must be rewritten.
  String? replacementRaw;

  String render() {
    final current = item;
    return switch (current) {
      StringsComment() => current.text,
      StringsEntry() => replacementRaw == null
          ? current.render()
          : '"${current.keyQuoted ? StringsEntry._toSingleLine(current.rawKey) : current.rawKey}" = "$replacementRaw";',
    };
  }
}

class _StringsScanner {
  _StringsScanner(String source, this._name)
      : _src = source.startsWith('﻿') ? source.substring(1) : source;

  final String _src;
  final String _name;
  int _pos = 0;

  StringsDocument scan() {
    final items = <StringsItem>[];
    while (true) {
      final newlines = _skipWhitespace();
      if (_pos >= _src.length) {
        break;
      }
      final blankLineBefore = items.isNotEmpty && newlines >= 2;
      if (_src.startsWith('/*', _pos)) {
        items.add(
          StringsComment(_readBlockComment(), blankLineBefore: blankLineBefore),
        );
        continue;
      }
      if (_src.startsWith('//', _pos)) {
        items.add(
          StringsComment(_readLineComment(), blankLineBefore: blankLineBefore),
        );
        continue;
      }
      items.add(_parseEntry(blankLineBefore));
    }
    return StringsDocument(items);
  }

  StringsEntry _parseEntry(bool blankLineBefore) {
    final start = _pos;
    final key = _readToken('key');
    _skipTrivia();
    if (_pos >= _src.length || _src[_pos] != '=') {
      if (_pos < _src.length && _src[_pos] == ';') {
        _fail('entries without a value ("key";) are not supported', _pos);
      }
      _fail('expected "=" after the key', _pos);
    }
    _pos++;
    _skipTrivia();
    final value = _readToken('value');
    _skipTrivia();
    if (_pos >= _src.length || _src[_pos] != ';') {
      _fail('expected ";" after the value', _pos);
    }
    _pos++;
    return StringsEntry(
      rawKey: key.raw,
      keyQuoted: key.quoted,
      rawValue: value.raw,
      valueQuoted: value.quoted,
      sourceText: _src.substring(start, _pos),
      blankLineBefore: blankLineBefore,
    );
  }

  ({String raw, bool quoted}) _readToken(String what) {
    if (_pos >= _src.length) {
      _fail('unexpected end of file, expected a $what', _pos);
    }
    if (_src[_pos] == '"') {
      final open = _pos;
      final start = ++_pos;
      while (_pos < _src.length) {
        final c = _src[_pos];
        if (c == r'\') {
          _pos += 2;
          continue;
        }
        if (c == '"') {
          final raw = _src.substring(start, _pos);
          _pos++;
          return (raw: raw, quoted: true);
        }
        _pos++;
      }
      _fail('unterminated quoted $what', open);
    }
    final start = _pos;
    while (_pos < _src.length && _isBareChar(_src.codeUnitAt(_pos))) {
      _pos++;
    }
    if (_pos == start) {
      _fail('unexpected character "${_src[_pos]}" where a $what was expected',
          _pos);
    }
    return (raw: _src.substring(start, _pos), quoted: false);
  }

  String _readBlockComment() {
    final start = _pos;
    final end = _src.indexOf('*/', _pos + 2);
    if (end < 0) {
      _fail('unterminated block comment', start);
    }
    _pos = end + 2;
    return _src.substring(start, _pos);
  }

  String _readLineComment() {
    final start = _pos;
    var end = _src.indexOf('\n', _pos);
    if (end < 0) {
      end = _src.length;
    }
    _pos = end;
    var text = _src.substring(start, end);
    if (text.endsWith('\r')) {
      text = text.substring(0, text.length - 1);
    }
    return text;
  }

  int _skipWhitespace() {
    var newlines = 0;
    while (_pos < _src.length) {
      final c = _src.codeUnitAt(_pos);
      if (c == 0x0A) {
        newlines++;
      }
      if (c == 0x20 ||
          c == 0x09 ||
          c == 0x0A ||
          c == 0x0D ||
          c == 0x0B ||
          c == 0x0C) {
        _pos++;
      } else {
        break;
      }
    }
    return newlines;
  }

  void _skipTrivia() {
    while (true) {
      _skipWhitespace();
      if (_src.startsWith('/*', _pos)) {
        _readBlockComment();
      } else if (_src.startsWith('//', _pos)) {
        _readLineComment();
      } else {
        return;
      }
    }
  }

  static bool _isBareChar(int c) =>
      (c >= 0x30 && c <= 0x39) || // 0-9
      (c >= 0x41 && c <= 0x5A) || // A-Z
      (c >= 0x61 && c <= 0x7A) || // a-z
      c == 0x5F || // _
      c == 0x2E || // .
      c == 0x24 || // $
      c == 0x3A || // :
      c == 0x2F || // /
      c == 0x2D || // -
      c == 0x2B; // +

  Never _fail(String message, int offset) {
    var line = 1;
    var column = 1;
    final limit = offset > _src.length ? _src.length : offset;
    for (var i = 0; i < limit; i++) {
      if (_src.codeUnitAt(i) == 0x0A) {
        line++;
        column = 1;
      } else {
        column++;
      }
    }
    throw LocalizerParseException(
      '$_name: $message (line $line, column $column).',
      path: _name,
      hint: 'Fix the syntax error manually and run again. '
          'Nothing was modified.',
    );
  }
}
