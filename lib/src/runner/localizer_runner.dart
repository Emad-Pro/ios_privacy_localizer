import 'dart:io';

import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

import '../exceptions/localizer_exception.dart';
import '../models/localizer_config.dart';
import '../parser/config_parser.dart';
import '../safety/plist_validator.dart';
import '../safety/text_codec.dart';
import '../safety/transaction_manager.dart';
import '../updaters/info_plist_updater.dart';
import '../updaters/pbxproj_updater.dart';
import '../updaters/strings_updater.dart';
import 'localizer_logger.dart';

/// Locations of the native files inside a Flutter project.
@immutable
class IosProjectPaths {
  /// Resolves the native file locations for the Flutter project at [projectRoot].
  IosProjectPaths(String projectRoot)
      : root = p.normalize(p.absolute(projectRoot));

  /// The Flutter project root (absolute).
  final String root;

  /// `ios/`
  String get iosDir => p.join(root, 'ios');

  /// `ios/Runner/`
  String get runnerDir => p.join(iosDir, 'Runner');

  /// `ios/Runner/Info.plist`
  String get infoPlist => p.join(runnerDir, 'Info.plist');

  /// `ios/Runner.xcodeproj/project.pbxproj`
  String get pbxproj => p.join(iosDir, 'Runner.xcodeproj', 'project.pbxproj');

  /// `ios/Runner/<locale>.lproj/InfoPlist.strings`
  String stringsFile(String locale) =>
      p.join(runnerDir, '$locale.lproj', 'InfoPlist.strings');

  /// [path] relative to [root], with forward slashes.
  String relative(String path) =>
      p.relative(path, from: root).replaceAll(r'\', '/');
}

/// A file that needs to be written.
@immutable
class PlannedChange {
  /// Creates a planned write of [content] to [path].
  const PlannedChange({
    required this.path,
    required this.displayPath,
    required this.content,
    required this.changes,
    required this.isNewFile,
  });

  /// Absolute path.
  final String path;

  /// Path relative to the project root.
  final String displayPath;

  /// The complete new content.
  final String content;

  /// Semantic changes, in order.
  final List<String> changes;

  /// Whether the file does not exist yet.
  final bool isNewFile;
}

/// Outcome of [LocalizerRunner.run].
@immutable
class RunReport {
  /// Creates the report of a run.
  RunReport({
    required this.config,
    required List<PlannedChange> changes,
    required this.dryRun,
  }) : changes = List<PlannedChange>.unmodifiable(changes);

  /// The effective configuration.
  final LocalizerConfig config;

  /// Files written (or that would be written in a dry run).
  final List<PlannedChange> changes;

  /// Whether this was a dry run.
  final bool dryRun;

  /// Whether nothing needed to change.
  bool get upToDate => changes.isEmpty;
}

/// Outcome of [LocalizerRunner.validate].
@immutable
class SyncReport {
  /// Creates a sync report from relative file path -> problems.
  SyncReport(Map<String, List<String>> issues)
      : issues = Map<String, List<String>>.unmodifiable(issues);

  /// Relative file path -> problems found in it.
  final Map<String, List<String>> issues;

  /// Whether the project matches the configuration.
  bool get inSync => issues.isEmpty;
}

/// Outcome of [LocalizerRunner.restore].
@immutable
class RestoreReport {
  /// Creates the report of a restore.
  RestoreReport(List<String> files, {required this.dryRun})
      : files = List<String>.unmodifiable(files);

  /// Relative paths of the restored files.
  final List<String> files;

  /// Whether this was a dry run.
  final bool dryRun;
}

/// Orchestrates the complete workflow: configuration, planning, atomic
/// writing, validation, sync checks and restore.
///
/// All new file contents are computed in memory first. Files are only
/// written after every updater succeeded, inside a [TransactionManager], so
/// a failure at any point leaves the project untouched.
class LocalizerRunner {
  /// Creates a runner for the Flutter project at [projectRoot].
  LocalizerRunner({
    required String projectRoot,
    this.configPath,
    LocalizerLogger? logger,
    this.validator = const PlistValidator(),
  })  : paths = IosProjectPaths(projectRoot),
        logger = logger ?? LocalizerLogger();

  /// Native file locations.
  final IosProjectPaths paths;

  /// Optional custom configuration file.
  final String? configPath;

  /// Console output.
  final LocalizerLogger logger;

  /// Validator used for pre-flight and post-write checks.
  final PlistValidator validator;

  /// Loads the configuration and applies CLI overrides.
  LocalizerConfig loadConfig({
    bool forceBackup = false,
    bool forceSkipPbxproj = false,
  }) {
    final config =
        ConfigParser(projectRoot: paths.root, configPath: configPath).load();
    final effective = config.copyWith(
      backup: config.backup || forceBackup,
      skipPbxproj: config.skipPbxproj || forceSkipPbxproj,
    );

    final source =
        config.source == null ? 'configuration' : _rel(config.source!);
    logger
      ..step('Configuration: $source')
      ..info(
        '${config.permissions.length} permission(s) · locales: '
        '${config.locales.join(', ')} · default: ${config.defaultLocale}',
      );
    for (final warning in config.warnings) {
      logger.warning(warning);
    }
    if (effective.skipPbxproj) {
      logger.info('project.pbxproj will not be modified (skip_pbxproj).');
    }
    return effective;
  }

  /// Applies the configuration to the iOS project.
  ///
  /// With [dryRun], every change is computed and printed but nothing is
  /// written.
  RunReport run({
    bool dryRun = false,
    bool forceBackup = false,
    bool forceSkipPbxproj = false,
  }) {
    final config = loadConfig(
      forceBackup: forceBackup,
      forceSkipPbxproj: forceSkipPbxproj,
    );
    _requireIosProject();

    final planned = <PlannedChange>[];
    final info = _planInfoPlist(config);
    if (info != null) {
      planned.add(info);
    }
    for (final locale in config.locales) {
      final strings = _planStrings(config, locale);
      if (strings != null) {
        planned.add(strings);
      }
    }
    if (!config.skipPbxproj) {
      final pbxproj = _planPbxproj(config);
      if (pbxproj != null) {
        planned.add(pbxproj);
      }
    }

    logger.blank();
    if (planned.isEmpty) {
      logger
          .success('Everything is already up to date. No files were modified.');
      return RunReport(config: config, changes: planned, dryRun: dryRun);
    }

    logger.step(dryRun ? 'Planned changes (dry run):' : 'Changes:');
    for (final change in planned) {
      logger.file(change.displayPath, isNew: change.isNewFile);
      for (final detail in change.changes) {
        logger.detail(detail);
      }
    }
    logger.blank();

    if (dryRun) {
      logger.success(
        'Dry run complete: ${planned.length} file(s) would change. '
        'No files were modified.',
      );
      return RunReport(config: config, changes: planned, dryRun: true);
    }

    _commit(planned, keepBackups: config.backup);
    return RunReport(config: config, changes: planned, dryRun: false);
  }

  /// Checks whether the project matches the configuration without writing.
  SyncReport validate({bool forceSkipPbxproj = false}) {
    final config = loadConfig(forceSkipPbxproj: forceSkipPbxproj);
    _requireIosProject();
    final issues = <String, List<String>>{};

    void check(String path, PlannedChange? Function() plan) {
      try {
        final change = plan();
        if (change != null) {
          issues[change.displayPath] = <String>[
            if (change.isNewFile) 'File is missing',
            ...change.changes,
          ];
        }
      } on LocalizerException catch (e) {
        issues[_rel(path)] = <String>[e.message, ...e.details];
      }
    }

    check(paths.infoPlist, () => _planInfoPlist(config));
    for (final locale in config.locales) {
      final path = paths.stringsFile(locale);
      check(path, () {
        if (File(path).existsSync()) {
          final result =
              validator.validateFile(path, kind: PlistFileKind.strings);
          if (!result.isValid) {
            throw LocalizerParseException(
              '${_rel(path)} is not a valid .strings file.',
              path: path,
              details: result.errors,
            );
          }
        }
        return _planStrings(config, locale);
      });
    }
    if (!config.skipPbxproj) {
      check(paths.pbxproj, () => _planPbxproj(config));
    }

    logger.blank();
    if (issues.isEmpty) {
      logger.success(
        'In sync: every configured permission and locale is present in '
        'Info.plist, InfoPlist.strings${config.skipPbxproj ? '' : ' and project.pbxproj'}.',
      );
    } else {
      logger.error('Out of sync: ${issues.length} file(s) need an update.');
      issues.forEach((file, problems) {
        logger.file(file, problem: true);
        for (final problem in problems) {
          logger.detail(problem);
        }
      });
      logger.blank();
      logger.info('Run `dart run ios_privacy_localizer` to fix it.');
    }
    return SyncReport(issues);
  }

  /// Restores `Info.plist`, `project.pbxproj` and every
  /// `<locale>.lproj/InfoPlist.strings` from their `.bak` files.
  ///
  /// Every backup is validated before anything is written, and the restore
  /// itself runs in a transaction. The `.bak` files are left in place.
  RestoreReport restore({bool dryRun = false}) {
    final candidates = <String>[paths.infoPlist, paths.pbxproj];
    final runnerDir = Directory(paths.runnerDir);
    if (runnerDir.existsSync()) {
      final lprojDirs = runnerDir
          .listSync()
          .whereType<Directory>()
          .where((dir) => dir.path.endsWith('.lproj'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
      for (final dir in lprojDirs) {
        candidates.add(p.join(dir.path, 'InfoPlist.strings'));
      }
    }

    final targets = candidates
        .where(
            (path) => File(TransactionManager.backupPathFor(path)).existsSync())
        .toList();
    if (targets.isEmpty) {
      throw LocalizerFileException(
        'No .bak backup files were found under ${_rel(paths.iosDir)}.',
        isMissing: true,
        hint: 'Backups are kept only when running with --backup '
            '(or `backup: true`).',
      );
    }

    logger.step(
        dryRun ? 'Backups that would be restored:' : 'Restoring backups:');
    final contents = <String, List<int>>{};
    for (final target in targets) {
      final backupPath = TransactionManager.backupPathFor(target);
      final result = validator.validateFile(
        backupPath,
        kind: PlistValidator.kindForPath(target),
      );
      if (!result.isValid) {
        throw LocalizerValidationException(
          '${_rel(backupPath)} is not valid; nothing was restored.',
          details: result.errors,
        );
      }
      contents[target] = File(backupPath).readAsBytesSync();
      logger.file(_rel(target));
      logger.detail('from ${_rel(backupPath)}');
    }

    if (dryRun) {
      logger.blank();
      logger.success('Dry run complete: no files were modified.');
      return RestoreReport(targets.map(_rel).toList(), dryRun: true);
    }

    final transaction = TransactionManager(validator: validator);
    try {
      contents.forEach(transaction.writeBytes);
      transaction.commit();
    } on Object {
      if (transaction.isOpen) {
        transaction.rollback();
      }
      rethrow;
    }

    logger.blank();
    logger.success(
        'Restored ${targets.length} file(s). The .bak files were kept.');
    logger.info(
      'Note: files created by a previous run (new .lproj folders) are not '
      'removed by --restore.',
    );
    return RestoreReport(targets.map(_rel).toList(), dryRun: false);
  }

  // ---------------------------------------------------------------------------
  // Planning (pure, in memory)
  // ---------------------------------------------------------------------------

  PlannedChange? _planInfoPlist(LocalizerConfig config) {
    final path = paths.infoPlist;
    final decoded = _readNative(path, PlistFileKind.infoPlist);
    final result = const InfoPlistUpdater().update(
      decoded.text,
      config.infoPlistValues,
      sourceName: _rel(path),
    );
    return _toChange(path, result, isNewFile: false);
  }

  PlannedChange? _planStrings(LocalizerConfig config, String locale) {
    final path = paths.stringsFile(locale);
    final type = FileSystemEntity.typeSync(path);
    if (type == FileSystemEntityType.directory) {
      throw LocalizerFileException(
        '${_rel(path)} is a directory, expected a file.',
        path: path,
      );
    }
    final exists = type != FileSystemEntityType.notFound;
    final existing = exists ? TextFileCodec.readFile(path).text : null;
    final result = const StringsUpdater().update(
      existing,
      config.translationsForLocale(locale),
      sourceName: _rel(path),
    );
    return _toChange(path, result, isNewFile: !exists);
  }

  PlannedChange? _planPbxproj(LocalizerConfig config) {
    final path = paths.pbxproj;
    final decoded = _readNative(path, PlistFileKind.pbxproj);
    final result = const PbxprojUpdater().update(
      decoded.text,
      config.locales,
      sourceName: _rel(path),
    );
    return _toChange(path, result, isNewFile: false);
  }

  PlannedChange? _toChange(
    String path,
    FileUpdateResult result, {
    required bool isNewFile,
  }) {
    if (!result.hasChanges) {
      return null;
    }
    return PlannedChange(
      path: path,
      displayPath: _rel(path),
      content: result.content,
      changes: result.changes,
      isNewFile: isNewFile,
    );
  }

  /// Reads a file that must exist and be valid before it is touched.
  DecodedText _readNative(String path, PlistFileKind kind) {
    final file = File(path);
    if (!file.existsSync()) {
      throw LocalizerFileException(
        '${_rel(path)} was not found.',
        path: path,
        isMissing: true,
        hint: kind == PlistFileKind.pbxproj
            ? 'Use --skip-pbxproj if this project has no Runner.xcodeproj.'
            : 'Run the tool from the Flutter project root or pass --path.',
      );
    }

    final List<int> bytes;
    try {
      bytes = file.readAsBytesSync();
    } on FileSystemException catch (e) {
      throw LocalizerFileException(
        'Unable to read ${_rel(path)}: ${e.message}',
        path: path,
      );
    }

    if (kind == PlistFileKind.infoPlist && _isBinaryPlist(bytes)) {
      throw LocalizerParseException(
        '${_rel(path)} is a binary property list.',
        path: path,
        hint: 'Convert it to XML first: plutil -convert xml1 ${_rel(path)}',
      );
    }

    final preflight = validator.validateFile(path, kind: kind);
    if (!preflight.isValid) {
      throw LocalizerParseException(
        '${_rel(path)} is already invalid before any modification. '
        'Nothing was changed.',
        path: path,
        details: preflight.errors,
        hint: 'Repair the file (or restore it from version control) and run '
            'again.',
      );
    }
    return TextFileCodec.decode(bytes, path: path);
  }

  // ---------------------------------------------------------------------------
  // Writing
  // ---------------------------------------------------------------------------

  void _commit(List<PlannedChange> planned, {required bool keepBackups}) {
    final transaction = TransactionManager(validator: validator);
    final ValidationReport report;
    try {
      for (final change in planned) {
        transaction.writeString(change.path, change.content);
      }
      report = transaction.commit(keepBackupFiles: keepBackups);
    } on Object {
      if (transaction.isOpen) {
        transaction.rollback();
      }
      logger.warning(
        'All changes were rolled back. Your iOS project files are exactly as '
        'they were before this run.',
      );
      rethrow;
    }

    final checks = report.checksPerformed.join(' + ');
    logger.success('Validated ${report.results.length} file(s) ($checks).');
    for (final warning in transaction.warnings) {
      logger.warning(warning);
    }
    if (keepBackups) {
      logger.info('Backups kept next to the modified files (*.bak). '
          'Use --restore to roll back.');
    }
    logger.success('Done. ${planned.length} file(s) updated safely.');
  }

  void _requireIosProject() {
    if (!Directory(paths.iosDir).existsSync()) {
      throw LocalizerFileException(
        'No ios/ directory found in ${paths.root}.',
        path: paths.iosDir,
        isMissing: true,
        hint: 'Run the tool from the Flutter project root or pass --path.',
      );
    }
  }

  static bool _isBinaryPlist(List<int> bytes) {
    const magic = <int>[0x62, 0x70, 0x6C, 0x69, 0x73, 0x74]; // "bplist"
    if (bytes.length < magic.length) {
      return false;
    }
    for (var i = 0; i < magic.length; i++) {
      if (bytes[i] != magic[i]) {
        return false;
      }
    }
    return true;
  }

  String _rel(String path) =>
      p.isWithin(paths.root, path) ? paths.relative(path) : path;
}
