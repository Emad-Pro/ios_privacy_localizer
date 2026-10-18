import 'dart:io';

import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:xml/xml.dart';

import '../exceptions/localizer_exception.dart';
import 'text_codec.dart';

/// The kinds of native files this tool edits.
enum PlistFileKind {
  /// An XML property list such as `Info.plist`.
  infoPlist,

  /// A `.strings` file such as `InfoPlist.strings`.
  strings,

  /// An Xcode `project.pbxproj` (old-style ASCII property list).
  pbxproj,
}

/// Validation outcome for one file.
@immutable
class FileValidationResult {
  const FileValidationResult({
    required this.path,
    required this.kind,
    this.errors = const <String>[],
    this.checks = const <String>[],
  });

  /// The validated file.
  final String path;

  /// The detected kind, or `null` for files that were skipped.
  final PlistFileKind? kind;

  /// Every problem found. Empty when the file is valid.
  final List<String> errors;

  /// The checks that ran (`structure`, `plutil -lint`, ...).
  final List<String> checks;

  /// Whether no problem was found.
  bool get isValid => errors.isEmpty;
}

/// Validation outcome for a set of files.
@immutable
class ValidationReport {
  ValidationReport(List<FileValidationResult> results)
      : results = List<FileValidationResult>.unmodifiable(results);

  /// One result per validated file.
  final List<FileValidationResult> results;

  /// Whether every file is valid.
  bool get isValid => results.every((result) => result.isValid);

  /// `path: error` lines for every invalid file.
  List<String> get errorMessages => <String>[
        for (final result in results)
          for (final error in result.errors) '${result.path}: $error',
      ];

  /// The distinct checks that ran across all files.
  Set<String> get checksPerformed => <String>{
        for (final result in results) ...result.checks,
      };
}

/// Validates `Info.plist`, `.strings` and `project.pbxproj` files.
///
/// A structural check implemented in Dart always runs (on every platform).
/// On macOS, `plutil -lint` additionally runs when available; it natively
/// understands XML plists, `.strings` files and `.pbxproj` files.
class PlistValidator {
  const PlistValidator({this.useNativeTools = true});

  /// Whether `plutil -lint` may be used on macOS.
  final bool useNativeTools;

  /// One `"KEY" = "VALUE";` entry per line.
  static final RegExp stringsLinePattern =
      RegExp(r'^"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;$');

  /// The mandatory first line of a `project.pbxproj`.
  static const String pbxprojHeader = r'// !$*UTF8*$!';

  static const Set<String> _plistScalarTypes = <String>{
    'string',
    'integer',
    'real',
    'true',
    'false',
    'date',
    'data',
  };

  /// Infers the kind from the file name (a trailing `.bak` is ignored).
  static PlistFileKind? kindForPath(String path) {
    var name = p.basename(path);
    if (name.endsWith('.bak')) {
      name = name.substring(0, name.length - 4);
    }
    if (name.endsWith('.pbxproj')) {
      return PlistFileKind.pbxproj;
    }
    if (name.endsWith('.strings')) {
      return PlistFileKind.strings;
    }
    if (name.endsWith('.plist')) {
      return PlistFileKind.infoPlist;
    }
    return null;
  }

  /// Validates every file in [paths].
  ValidationReport validateAll(Iterable<String> paths) =>
      ValidationReport(<FileValidationResult>[
        for (final path in paths) validateFile(path),
      ]);

  /// Validates the file at [path] as [kind] (inferred from the name if
  /// omitted). Files of unknown kind are reported as valid and skipped.
  FileValidationResult validateFile(String path, {PlistFileKind? kind}) {
    final effectiveKind = kind ?? kindForPath(path);
    if (effectiveKind == null) {
      return FileValidationResult(
        path: path,
        kind: null,
        checks: const <String>['skipped (unknown file type)'],
      );
    }

    final String content;
    try {
      content = TextFileCodec.readFile(path).text;
    } on LocalizerException catch (e) {
      return FileValidationResult(
        path: path,
        kind: effectiveKind,
        errors: <String>[e.message],
        checks: const <String>['read'],
      );
    }

    final errors = <String>[...validateContent(content, effectiveKind)];
    final checks = <String>['structure'];

    if (errors.isEmpty && useNativeTools && Platform.isMacOS) {
      final nativeErrors = _runPlutil(path);
      if (nativeErrors != null) {
        checks.add('plutil -lint');
        errors.addAll(nativeErrors);
      }
    }

    return FileValidationResult(
      path: path,
      kind: effectiveKind,
      errors: errors,
      checks: checks,
    );
  }

  /// Runs the platform independent structural check on [content].
  List<String> validateContent(String content, PlistFileKind kind) {
    final text = content.startsWith('﻿') ? content.substring(1) : content;
    return switch (kind) {
      PlistFileKind.infoPlist => _checkInfoPlist(text),
      PlistFileKind.strings => _checkStrings(text),
      PlistFileKind.pbxproj => _checkPbxproj(text),
    };
  }

  /// Returns `null` when `plutil` is unavailable.
  List<String>? _runPlutil(String path) {
    try {
      final result = Process.runSync('plutil', <String>['-lint', path]);
      if (result.exitCode == 0) {
        return const <String>[];
      }
      final output = '${result.stdout}'.trim();
      final error = '${result.stderr}'.trim();
      final message = <String>[
        if (output.isNotEmpty) output,
        if (error.isNotEmpty) error,
      ].join(' ');
      return <String>[
        'plutil -lint failed (exit ${result.exitCode})'
            '${message.isEmpty ? '' : ': $message'}',
      ];
    } on ProcessException {
      return null;
    }
  }

  // ---------------------------------------------------------------------------
  // Info.plist
  // ---------------------------------------------------------------------------

  static List<String> _checkInfoPlist(String content) {
    final XmlDocument document;
    try {
      document = XmlDocument.parse(content);
    } on XmlException catch (e) {
      return <String>['not well-formed XML: $e'];
    }

    final roots = document.childElements.toList();
    if (roots.length != 1 || roots.single.name.local != 'plist') {
      return <String>['the root element must be <plist>'];
    }
    final top = roots.single.childElements.toList();
    if (top.length != 1 || top.single.name.local != 'dict') {
      return <String>['<plist> must contain exactly one top-level <dict>'];
    }

    final errors = <String>[];
    _checkPlistValue(top.single, '/plist/dict', errors);
    return errors;
  }

  static void _checkPlistValue(
    XmlElement element,
    String where,
    List<String> errors,
  ) {
    final name = element.name.local;

    if (_plistScalarTypes.contains(name)) {
      if (element.childElements.isNotEmpty) {
        errors.add('<$name> must not contain child elements ($where)');
      }
      if ((name == 'true' || name == 'false') &&
          element.innerText.trim().isNotEmpty) {
        errors.add('<$name/> must be empty ($where)');
      }
      return;
    }

    if (name == 'array') {
      _checkNoText(element, where, errors);
      for (final child in element.childElements) {
        _checkPlistValue(child, '$where/array', errors);
      }
      return;
    }

    if (name == 'dict') {
      _checkNoText(element, where, errors);
      final children = element.childElements.toList();
      for (var i = 0; i < children.length; i += 2) {
        final key = children[i];
        if (key.name.local != 'key') {
          errors.add(
            'expected <key> but found <${key.name.local}> ($where)',
          );
          return;
        }
        final keyName = key.innerText.trim();
        if (i + 1 >= children.length) {
          errors.add('<key>$keyName</key> has no value ($where)');
          return;
        }
        final value = children[i + 1];
        if (value.name.local == 'key') {
          errors.add('<key>$keyName</key> has no value ($where)');
          return;
        }
        _checkPlistValue(value, '$where/$keyName', errors);
      }
      return;
    }

    errors.add('unsupported element <$name> ($where)');
  }

  static void _checkNoText(
    XmlElement element,
    String where,
    List<String> errors,
  ) {
    for (final node in element.children) {
      if ((node is XmlText && node.value.trim().isNotEmpty) ||
          node is XmlCDATA) {
        errors.add('unexpected text inside <${element.name.local}> ($where)');
        return;
      }
    }
  }

  // ---------------------------------------------------------------------------
  // .strings
  // ---------------------------------------------------------------------------

  static List<String> _checkStrings(String content) {
    final String stripped;
    try {
      stripped = _stripStringsComments(content);
    } on FormatException catch (e) {
      return <String>[e.message];
    }

    final errors = <String>[];
    final lines = stripped.split('\n');
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i].trim();
      if (line.isEmpty) {
        continue;
      }
      if (!stringsLinePattern.hasMatch(line)) {
        errors
            .add('line ${i + 1} is not a valid "KEY" = "VALUE"; entry: $line');
      }
    }
    return errors;
  }

  /// Replaces comments with nothing while keeping line numbers intact.
  static String _stripStringsComments(String content) {
    final out = StringBuffer();
    var i = 0;
    var line = 1;
    while (i < content.length) {
      final c = content[i];
      if (c == '\n') {
        line++;
        out.write(c);
        i++;
        continue;
      }
      if (c == '"') {
        final startLine = line;
        out.write(c);
        i++;
        var closed = false;
        while (i < content.length) {
          final d = content[i];
          if (d == '\\' && i + 1 < content.length) {
            out
              ..write(d)
              ..write(content[i + 1]);
            if (content[i + 1] == '\n') {
              line++;
            }
            i += 2;
            continue;
          }
          if (d == '\n') {
            line++;
          }
          out.write(d);
          i++;
          if (d == '"') {
            closed = true;
            break;
          }
        }
        if (!closed) {
          throw FormatException(
            'unterminated quoted string starting on line $startLine',
          );
        }
        continue;
      }
      if (c == '/' && i + 1 < content.length) {
        final next = content[i + 1];
        if (next == '*') {
          final end = content.indexOf('*/', i + 2);
          if (end < 0) {
            throw FormatException(
              'unterminated block comment starting on line $line',
            );
          }
          final comment = content.substring(i, end + 2);
          final newlines = '\n'.allMatches(comment).length;
          line += newlines;
          out.write('\n' * newlines);
          i = end + 2;
          continue;
        }
        if (next == '/') {
          final end = content.indexOf('\n', i);
          i = end < 0 ? content.length : end;
          continue;
        }
      }
      out.write(c);
      i++;
    }
    return out.toString();
  }

  // ---------------------------------------------------------------------------
  // project.pbxproj
  // ---------------------------------------------------------------------------

  static List<String> _checkPbxproj(String content) {
    final errors = <String>[];
    if (!content.startsWith(pbxprojHeader)) {
      errors.add('missing "$pbxprojHeader" header on the first line');
    }

    // Brackets are counted outside quoted strings and comments only, so
    // shell scripts and build settings such as "$(inherited)" never produce
    // false positives.
    final stack = <(String, int)>[];
    var line = 1;
    var i = 0;
    while (i < content.length) {
      final c = content[i];
      if (c == '\n') {
        line++;
        i++;
        continue;
      }
      if (c == '"') {
        final startLine = line;
        i++;
        var closed = false;
        while (i < content.length) {
          final d = content[i];
          if (d == '\\') {
            if (i + 1 < content.length && content[i + 1] == '\n') {
              line++;
            }
            i += 2;
            continue;
          }
          if (d == '\n') {
            line++;
          }
          i++;
          if (d == '"') {
            closed = true;
            break;
          }
        }
        if (!closed) {
          errors.add('unterminated quoted string starting on line $startLine');
          return errors;
        }
        continue;
      }
      if (c == '/' && i + 1 < content.length) {
        final next = content[i + 1];
        if (next == '/') {
          final end = content.indexOf('\n', i);
          i = end < 0 ? content.length : end;
          continue;
        }
        if (next == '*') {
          final end = content.indexOf('*/', i + 2);
          if (end < 0) {
            errors.add('unterminated comment starting on line $line');
            return errors;
          }
          line += '\n'.allMatches(content.substring(i, end)).length;
          i = end + 2;
          continue;
        }
      }
      if (c == '{' || c == '(') {
        stack.add((c, line));
      } else if (c == '}' || c == ')') {
        if (stack.isEmpty) {
          errors.add('unbalanced "$c" on line $line');
          return errors;
        }
        final (open, openLine) = stack.removeLast();
        final expected = open == '{' ? '}' : ')';
        if (c != expected) {
          errors.add(
            'mismatched "$c" on line $line (expected "$expected" for the '
            '"$open" opened on line $openLine)',
          );
          return errors;
        }
      }
      i++;
    }

    if (stack.isNotEmpty) {
      final (open, openLine) = stack.last;
      errors.add('unbalanced "$open" opened on line $openLine is never closed');
    }
    if (!RegExp(r'\brootObject\s*=').hasMatch(content)) {
      errors.add('missing "rootObject =" entry');
    }
    return errors;
  }
}
