import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../exceptions/localizer_exception.dart';
import 'plist_validator.dart';
import 'text_codec.dart';

/// Lifecycle of a [TransactionManager].
enum TransactionState {
  /// Files may be written.
  open,

  /// [TransactionManager.commit] succeeded.
  committed,

  /// [TransactionManager.rollback] ran (explicitly or after a failed commit).
  rolledBack,
}

/// Atomic, all-or-nothing editing of several files.
///
/// * Before an existing file is first modified its exact bytes are kept in
///   memory and written to `<file>.bak` on disk.
/// * New files and directories are registered so a rollback can delete them.
/// * Every write goes to a temporary file that is verified and then renamed
///   over the target, so a file is never left half written.
/// * [commit] validates every modified file; if validation fails, everything
///   is rolled back automatically.
class TransactionManager {
  /// Creates an open transaction that validates files with [validator] on commit.
  TransactionManager({PlistValidator validator = const PlistValidator()})
      : _validator = validator;

  final PlistValidator _validator;

  /// Absolute path -> exact original bytes of every pre-existing file.
  final Map<String, Uint8List> _existingFilesSnapshot = <String, Uint8List>{};

  /// Files that did not exist before this transaction.
  final Set<String> _newlyCreatedFiles = <String>{};

  /// Directories that did not exist before this transaction.
  final Set<String> _newlyCreatedDirs = <String>{};

  /// `.bak` path -> bytes of a `.bak` file that already existed before this
  /// transaction (`null` when the transaction created it).
  final Map<String, Uint8List?> _backupFiles = <String, Uint8List?>{};

  /// Every file written by this transaction, in write order.
  final Set<String> _modifiedFiles = <String>{};

  final List<String> _warnings = <String>[];

  TransactionState _state = TransactionState.open;

  /// Suffix of the temporary file used for atomic writes.
  static final String _tempSuffix = '.ipl-$pid.tmp';

  /// The current lifecycle state.
  TransactionState get state => _state;

  /// Whether files may still be written.
  bool get isOpen => _state == TransactionState.open;

  /// Every file written so far (absolute paths).
  Set<String> get modifiedFiles => Set<String>.unmodifiable(_modifiedFiles);

  /// Every `.bak` file written by this transaction (absolute paths).
  Set<String> get backupFiles => Set<String>.unmodifiable(_backupFiles.keys);

  /// Non-fatal problems that happened while cleaning up after [commit].
  List<String> get warnings => List<String>.unmodifiable(_warnings);

  /// The backup path used for [filePath].
  static String backupPathFor(String filePath) => '$filePath.bak';

  /// Snapshots [filePath] in memory and writes `<filePath>.bak`.
  ///
  /// Calling it again for the same file (or for a file this transaction
  /// created) is a no-op, so the snapshot always holds the original content.
  void backupFile(String filePath) {
    _ensureOpen();
    final path = _normalize(filePath);
    if (_existingFilesSnapshot.containsKey(path) ||
        _newlyCreatedFiles.contains(path)) {
      return;
    }

    final file = File(path);
    if (!file.existsSync()) {
      throw LocalizerFileException(
        'Cannot back up $path because it does not exist.',
        path: path,
        isMissing: true,
      );
    }

    final Uint8List original;
    try {
      original = file.readAsBytesSync();
    } on FileSystemException catch (e) {
      throw LocalizerFileException(
        'Unable to read $path for backup: ${e.message}',
        path: path,
      );
    }
    _existingFilesSnapshot[path] = original;

    final backupPath = backupPathFor(path);
    if (!_backupFiles.containsKey(backupPath)) {
      final backup = File(backupPath);
      _backupFiles[backupPath] =
          backup.existsSync() ? backup.readAsBytesSync() : null;
    }
    _writeAtomically(backupPath, original);
  }

  /// Registers [filePath] as a file this transaction is about to create.
  ///
  /// Throws an [ArgumentError] if the file already exists, because a
  /// rollback would otherwise delete a file the developer owns.
  void registerNewFile(String filePath) {
    _ensureOpen();
    final path = _normalize(filePath);
    if (_newlyCreatedFiles.contains(path)) {
      return;
    }
    if (FileSystemEntity.typeSync(path) != FileSystemEntityType.notFound) {
      throw ArgumentError.value(
        filePath,
        'filePath',
        'already exists; use backupFile() for existing files',
      );
    }
    _newlyCreatedFiles.add(path);
  }

  /// Registers [dirPath] as a directory this transaction is about to create.
  ///
  /// Pre-existing directories are ignored, so they are never deleted.
  void registerNewDirectory(String dirPath) {
    _ensureOpen();
    final path = _normalize(dirPath);
    if (Directory(path).existsSync()) {
      return;
    }
    _newlyCreatedDirs.add(path);
  }

  /// Writes [content] to [filePath] atomically.
  ///
  /// Existing files are backed up first and keep their original text
  /// encoding unless [encoding] is given; new files (and any missing parent
  /// directories) are registered for deletion on rollback.
  void writeString(
    String filePath,
    String content, {
    TextEncodingKind? encoding,
  }) {
    _ensureOpen();
    final path = _normalize(filePath);
    var effective = encoding ?? TextEncodingKind.utf8;
    if (encoding == null) {
      final original = _existingFilesSnapshot[path];
      if (original != null) {
        effective = TextFileCodec.detect(original);
      } else if (File(path).existsSync()) {
        effective = TextFileCodec.detect(File(path).readAsBytesSync());
      }
    }
    writeBytes(path, TextFileCodec.encode(content, effective));
  }

  /// Writes [bytes] to [filePath] atomically (see [writeString]).
  void writeBytes(String filePath, List<int> bytes) {
    _ensureOpen();
    final path = _normalize(filePath);
    final type = FileSystemEntity.typeSync(path);
    if (type == FileSystemEntityType.directory) {
      throw LocalizerFileException(
        'Cannot write $path because it is a directory.',
        path: path,
      );
    }
    if (type == FileSystemEntityType.notFound) {
      _createParentDirectories(File(path).parent);
      registerNewFile(path);
    } else {
      backupFile(path);
    }
    _writeAtomically(path, bytes);
    _modifiedFiles.add(path);
  }

  /// Validates every modified file and finalizes the transaction.
  ///
  /// When validation fails the transaction is rolled back and a
  /// [LocalizerValidationException] is thrown. On success, `.bak` files are
  /// deleted unless [keepBackupFiles] is `true` (a `.bak` file that existed
  /// before this transaction is restored to its previous content instead).
  ValidationReport commit({bool keepBackupFiles = false}) {
    _ensureOpen();

    final ValidationReport report;
    try {
      report = _validator.validateAll(
        _modifiedFiles.where((path) => File(path).existsSync()),
      );
    } on Object {
      rollback();
      rethrow;
    }

    if (!report.isValid) {
      rollback();
      throw LocalizerValidationException(
        'Validation failed after writing; every change was rolled back and '
        'your files are exactly as they were.',
        details: report.errorMessages,
      );
    }

    if (!keepBackupFiles) {
      _discardBackups(_warnings);
    }
    _state = TransactionState.committed;
    return report;
  }

  /// Restores every snapshotted file to its exact original bytes, deletes
  /// files and directories created by this transaction, and cleans up the
  /// `.bak` files it wrote.
  ///
  /// Every step is attempted even if an earlier one fails; failures are
  /// reported together in a [LocalizerRollbackException]. Calling it on a
  /// transaction that is no longer open is a no-op.
  void rollback() {
    if (_state != TransactionState.open) {
      return;
    }
    _state = TransactionState.rolledBack;

    final failures = <String>[];

    for (final entry in _existingFilesSnapshot.entries) {
      try {
        _writeAtomically(entry.key, entry.value);
      } on Object catch (e) {
        failures.add('${entry.key}: could not be restored ($e). '
            'Its original content is in ${backupPathFor(entry.key)}');
      }
    }

    for (final path in _newlyCreatedFiles) {
      try {
        final file = File(path);
        if (file.existsSync()) {
          file.deleteSync();
        }
      } on Object catch (e) {
        failures.add('$path: newly created file could not be deleted ($e)');
      }
    }

    final dirs = _newlyCreatedDirs.toList()
      ..sort((a, b) => b.length.compareTo(a.length));
    for (final path in dirs) {
      try {
        final dir = Directory(path);
        if (dir.existsSync() && dir.listSync().isEmpty) {
          dir.deleteSync();
        }
      } on Object catch (e) {
        failures
            .add('$path: newly created directory could not be deleted ($e)');
      }
    }

    final restoreFailed = failures
        .where((failure) => failure.contains('could not be restored'))
        .isNotEmpty;
    if (!restoreFailed) {
      _discardBackups(failures);
    }

    if (failures.isNotEmpty) {
      throw LocalizerRollbackException(
        'Rollback could not complete for ${failures.length} item(s).',
        details: failures,
        hint: 'Check the listed files manually; .bak files next to them '
            'contain the original content.',
      );
    }
  }

  void _discardBackups(List<String> problems) {
    for (final entry in _backupFiles.entries) {
      try {
        final previous = entry.value;
        if (previous == null) {
          final file = File(entry.key);
          if (file.existsSync()) {
            file.deleteSync();
          }
        } else {
          _writeAtomically(entry.key, previous);
        }
      } on Object catch (e) {
        problems.add('${entry.key}: backup file could not be cleaned up ($e)');
      }
    }
  }

  void _createParentDirectories(Directory directory) {
    final missing = <String>[];
    var current = Directory(_normalize(directory.path));
    while (!current.existsSync()) {
      missing.add(current.path);
      final parent = current.parent;
      if (parent.path == current.path) {
        break;
      }
      current = parent;
    }
    for (final path in missing.reversed) {
      registerNewDirectory(path);
      try {
        Directory(path).createSync();
      } on FileSystemException catch (e) {
        throw LocalizerFileException(
          'Unable to create directory $path: ${e.message}',
          path: path,
        );
      }
    }
  }

  void _writeAtomically(String path, List<int> bytes) {
    var target = path;
    if (FileSystemEntity.isLinkSync(path)) {
      target = File(path).resolveSymbolicLinksSync();
    }
    final temp = File('$target$_tempSuffix');
    try {
      temp.writeAsBytesSync(bytes, flush: true);
      final written = temp.readAsBytesSync();
      if (!_bytesEqual(written, bytes)) {
        throw LocalizerFileException(
          'Verification of the temporary file for $path failed.',
          path: path,
        );
      }
      temp.renameSync(target);
    } on FileSystemException catch (e) {
      _deleteQuietly(temp);
      throw LocalizerFileException(
        'Unable to write $path: ${e.message}',
        path: path,
      );
    } on Object {
      _deleteQuietly(temp);
      rethrow;
    }
  }

  void _ensureOpen() {
    if (_state != TransactionState.open) {
      throw StateError('The transaction is already ${_state.name}.');
    }
  }

  static String _normalize(String path) => p.normalize(p.absolute(path));

  static bool _bytesEqual(List<int> a, List<int> b) {
    if (a.length != b.length) {
      return false;
    }
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) {
        return false;
      }
    }
    return true;
  }

  static void _deleteQuietly(File file) {
    try {
      if (file.existsSync()) {
        file.deleteSync();
      }
    } on Object {
      // Nothing else can be done; the temporary file is harmless.
    }
  }
}
