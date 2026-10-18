/// Process exit codes returned by the `ios_privacy_localizer` CLI.
///
/// Values follow the BSD `sysexits.h` conventions where one applies.
abstract final class LocalizerExitCode {
  /// Everything succeeded (or the project is in sync for `--validate`).
  static const int success = 0;

  /// `--validate` detected that the iOS project is out of sync with the
  /// configuration.
  static const int outOfSync = 1;

  /// The command line was used incorrectly.
  static const int usage = 64;

  /// The configuration or a native project file contains invalid data.
  static const int dataError = 65;

  /// A required input file (config, Info.plist, project.pbxproj, backup) is
  /// missing.
  static const int noInput = 66;

  /// An internal error, or post-write validation failed and the transaction
  /// was rolled back.
  static const int software = 70;

  /// Reading or writing a file failed.
  static const int ioError = 74;
}

/// Base class for every error raised by `ios_privacy_localizer`.
///
/// Each subclass maps to a dedicated CLI [exitCode], carries a human readable
/// [message], optional [details] (one line each) and an optional [hint] that
/// tells the developer how to fix the problem.
abstract class LocalizerException implements Exception {
  const LocalizerException(
    this.message, {
    this.hint,
    this.details = const <String>[],
  });

  /// What went wrong.
  final String message;

  /// How to fix it, when a concrete suggestion exists.
  final String? hint;

  /// Additional diagnostic lines (for example individual validation errors).
  final List<String> details;

  /// The process exit code the CLI should return for this error.
  int get exitCode;

  @override
  String toString() {
    final buffer = StringBuffer('$runtimeType: $message');
    for (final detail in details) {
      buffer.write('\n  - $detail');
    }
    if (hint != null) {
      buffer.write('\nHint: $hint');
    }
    return buffer.toString();
  }
}

/// The command line arguments are invalid or contradictory.
class LocalizerUsageException extends LocalizerException {
  const LocalizerUsageException(super.message, {super.hint, super.details});

  @override
  int get exitCode => LocalizerExitCode.usage;
}

/// The YAML configuration is missing, malformed or semantically invalid.
class LocalizerConfigException extends LocalizerException {
  const LocalizerConfigException(super.message, {super.hint, super.details});

  @override
  int get exitCode => LocalizerExitCode.dataError;
}

/// A file could not be found, read or written.
class LocalizerFileException extends LocalizerException {
  const LocalizerFileException(
    super.message, {
    this.path,
    this.isMissing = false,
    super.hint,
    super.details,
  });

  /// The file the error relates to, if known.
  final String? path;

  /// `true` when the error is caused by a file that does not exist.
  final bool isMissing;

  @override
  int get exitCode =>
      isMissing ? LocalizerExitCode.noInput : LocalizerExitCode.ioError;
}

/// A native iOS file (Info.plist, InfoPlist.strings, project.pbxproj) could
/// not be parsed. Nothing is ever written when this is thrown.
class LocalizerParseException extends LocalizerException {
  const LocalizerParseException(
    super.message, {
    this.path,
    super.hint,
    super.details,
  });

  /// The file that failed to parse, if known.
  final String? path;

  @override
  int get exitCode => LocalizerExitCode.dataError;
}

/// `project.pbxproj` does not have the structure required for a safe edit
/// (for example the `Runner` group or target cannot be located).
class LocalizerPbxprojException extends LocalizerParseException {
  const LocalizerPbxprojException(
    super.message, {
    super.path,
    super.hint,
    super.details,
  });
}

/// Post-write validation failed. When this is thrown by
/// `TransactionManager.commit`, every change has already been rolled back.
class LocalizerValidationException extends LocalizerException {
  const LocalizerValidationException(super.message,
      {super.hint, super.details});

  @override
  int get exitCode => LocalizerExitCode.software;
}

/// Restoring the original files during a rollback failed for at least one
/// file. [details] lists every file that could not be restored; the `.bak`
/// files next to them still contain the original content.
class LocalizerRollbackException extends LocalizerException {
  const LocalizerRollbackException(super.message, {super.hint, super.details});

  @override
  int get exitCode => LocalizerExitCode.ioError;
}
