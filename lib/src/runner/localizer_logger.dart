import 'dart:io';

import '../version.dart';

/// Console output with optional ANSI colors.
///
/// Colors are disabled automatically when the terminal does not support ANSI
/// escapes or when the `NO_COLOR` environment variable is set.
class LocalizerLogger {
  LocalizerLogger({StringSink? out, StringSink? err, bool? color})
      : _out = out ?? stdout,
        _err = err ?? stderr,
        _color = color ?? _supportsColor();

  /// A logger that writes everything, uncolored, into [buffer].
  factory LocalizerLogger.buffered(StringBuffer buffer) =>
      LocalizerLogger(out: buffer, err: buffer, color: false);

  final StringSink _out;
  final StringSink _err;
  final bool _color;

  static const String _bold = '1';
  static const String _dim = '2';
  static const String _red = '31';
  static const String _green = '32';
  static const String _yellow = '33';
  static const String _magenta = '35';
  static const String _cyan = '36';

  static bool _supportsColor() {
    if (Platform.environment.containsKey('NO_COLOR')) {
      return false;
    }
    try {
      return stdout.hasTerminal && stdout.supportsAnsiEscapes;
    } on Object {
      return false;
    }
  }

  String _paint(String text, String code) =>
      _color ? '\x1B[${code}m$text\x1B[0m' : text;

  /// Prints the tool banner.
  void banner() {
    const width = 62;
    const line1 =
        '  ios_privacy_localizer v$packageVersion - Created by Emad Younis';
    const line2 = '  Safe iOS Permission & InfoPlist.strings Localization Tool';
    final edge = _paint('║', _cyan);
    _out
      ..writeln(_paint('╔${'═' * width}╗', _cyan))
      ..writeln('$edge${_paint(line1.padRight(width), _bold)}$edge')
      ..writeln('$edge${line2.padRight(width)}$edge')
      ..writeln(_paint('╚${'═' * width}╝', _cyan))
      ..writeln();
  }

  /// A top-level step.
  void step(String message) =>
      _out.writeln('${_paint('▸', _cyan)} ${_paint(message, _bold)}');

  /// Plain indented information.
  void info(String message) => _out.writeln('  $message');

  /// A successful outcome.
  void success(String message) =>
      _out.writeln('${_paint('✔', _green)} $message');

  /// A non-fatal problem.
  void warning(String message) =>
      _out.writeln('${_paint('⚠', _yellow)} ${_paint(message, _yellow)}');

  /// A fatal problem (written to stderr).
  void error(String message) =>
      _err.writeln('${_paint('✖', _red)} ${_paint(message, _red)}');

  /// How to fix the previous error (written to stderr).
  void hint(String message) {
    final lines = message.split('\n');
    _err.writeln('  ${_paint('Hint:', _bold)} ${lines.first}');
    for (final line in lines.skip(1)) {
      _err.writeln('        $line');
    }
  }

  /// A file that is (or would be) touched.
  void file(String path, {bool isNew = false, bool problem = false}) {
    final marker = problem
        ? _paint('✘', _red)
        : isNew
            ? _paint('✚', _green)
            : _paint('✎', _magenta);
    _out.writeln('  $marker $path${isNew ? _paint(' (new file)', _dim) : ''}');
  }

  /// A detail line under a [file] or [error].
  void detail(String message, {bool toStderr = false}) =>
      (toStderr ? _err : _out).writeln('      ${_paint('•', _dim)} $message');

  /// An empty line.
  void blank() => _out.writeln();
}
