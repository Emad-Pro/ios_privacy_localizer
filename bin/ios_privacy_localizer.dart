import 'dart:async';
import 'dart:io';

import 'package:args/args.dart';
import 'package:ios_privacy_localizer/ios_privacy_localizer.dart';

Future<void> main(List<String> arguments) async {
  exitCode = await runCli(arguments);
}

ArgParser _buildParser() => ArgParser()
  ..addOption(
    'path',
    abbr: 'p',
    defaultsTo: '.',
    valueHelp: 'dir',
    help: 'Path to the Flutter project root.',
  )
  ..addOption(
    'config',
    abbr: 'c',
    valueHelp: 'file',
    help: 'Custom YAML configuration file '
        '(default: ios_privacy_localizer.yaml, then pubspec.yaml).',
  )
  ..addFlag(
    'dry-run',
    negatable: false,
    help: 'Parse the config and print every planned change without '
        'modifying any file.',
  )
  ..addFlag(
    'backup',
    negatable: false,
    help: 'Keep the .bak files after a successful run.',
  )
  ..addFlag(
    'restore',
    negatable: false,
    help: 'Restore Info.plist, project.pbxproj and InfoPlist.strings from '
        'their .bak files.',
  )
  ..addFlag(
    'validate',
    negatable: false,
    help: 'Check that the project matches the config without writing '
        '(exit 0 = in sync, 1 = out of sync). Ideal for CI/CD.',
  )
  ..addFlag(
    'skip-pbxproj',
    negatable: false,
    help: 'Only update Info.plist and <locale>.lproj/InfoPlist.strings.',
  )
  ..addFlag(
    'color',
    defaultsTo: true,
    help: 'Use ANSI colors (also disabled by the NO_COLOR variable).',
  )
  ..addFlag(
    'version',
    negatable: false,
    help: 'Print the version and exit.',
  )
  ..addFlag(
    'help',
    abbr: 'h',
    negatable: false,
    help: 'Print this usage information.',
  );

String _usage(ArgParser parser) => '''
Usage: dart run ios_privacy_localizer [options]

Localizes iOS permission usage descriptions (NS*UsageDescription) declared in
pubspec.yaml or ios_privacy_localizer.yaml.

${parser.usage}

Exit codes:
  0   success / project in sync
  1   --validate: project out of sync
  64  invalid command line usage
  65  invalid configuration or native project file
  66  required file not found
  70  validation failed after writing (all changes rolled back)
  74  file read/write failure''';

/// Runs the CLI and returns the process exit code.
Future<int> runCli(List<String> arguments) async {
  final parser = _buildParser();
  final ArgResults results;
  try {
    results = parser.parse(arguments);
  } on FormatException catch (e) {
    stderr
      ..writeln('Error: ${e.message}')
      ..writeln()
      ..writeln(_usage(parser));
    return LocalizerExitCode.usage;
  }

  final logger =
      LocalizerLogger(color: results['color'] as bool ? null : false);

  if (results['help'] as bool) {
    logger.banner();
    stdout.writeln(_usage(parser));
    return LocalizerExitCode.success;
  }
  if (results['version'] as bool) {
    stdout.writeln('ios_privacy_localizer $packageVersion');
    return LocalizerExitCode.success;
  }

  final restore = results['restore'] as bool;
  final validate = results['validate'] as bool;
  final dryRun = results['dry-run'] as bool;
  final backup = results['backup'] as bool;
  final skipPbxproj = results['skip-pbxproj'] as bool;

  String? usageError;
  if (results.rest.isNotEmpty) {
    usageError = 'Unexpected argument(s): ${results.rest.join(' ')}';
  } else if (restore && validate) {
    usageError = '--restore and --validate cannot be combined.';
  } else if (validate && dryRun) {
    usageError = '--validate never writes files; drop --dry-run.';
  } else if (restore && (backup || skipPbxproj)) {
    usageError =
        '--restore cannot be combined with --backup or --skip-pbxproj.';
  }
  if (usageError != null) {
    logger.error(usageError);
    stderr
      ..writeln()
      ..writeln(_usage(parser));
    return LocalizerExitCode.usage;
  }

  logger.banner();

  // Defer Ctrl+C / SIGTERM while files are being written: the transaction
  // always finishes (commit or rollback) before the process exits.
  final subscriptions = <StreamSubscription<ProcessSignal>>[];
  void watch(ProcessSignal signal) {
    try {
      subscriptions.add(
        signal.watch().listen(
              (_) => logger.warning(
                'Interrupt received; finishing the current operation safely.',
              ),
            ),
      );
    } on Object {
      // Signal not supported on this platform.
    }
  }

  watch(ProcessSignal.sigint);
  if (!Platform.isWindows) {
    watch(ProcessSignal.sigterm);
  }

  try {
    final runner = LocalizerRunner(
      projectRoot: results['path'] as String,
      configPath: results['config'] as String?,
      logger: logger,
    );

    if (restore) {
      runner.restore(dryRun: dryRun);
      return LocalizerExitCode.success;
    }
    if (validate) {
      final report = runner.validate(forceSkipPbxproj: skipPbxproj);
      return report.inSync
          ? LocalizerExitCode.success
          : LocalizerExitCode.outOfSync;
    }
    runner.run(
      dryRun: dryRun,
      forceBackup: backup,
      forceSkipPbxproj: skipPbxproj,
    );
    return LocalizerExitCode.success;
  } on LocalizerException catch (e) {
    logger.error(e.message);
    for (final detail in e.details) {
      logger.detail(detail, toStderr: true);
    }
    final hint = e.hint;
    if (hint != null) {
      logger.hint(hint);
    }
    return e.exitCode;
  } on Object catch (e, stackTrace) {
    logger
      ..error('Unexpected internal error: $e')
      ..detail('$stackTrace'.trim(), toStderr: true)
      ..hint('Please report this issue together with the output above.');
    return LocalizerExitCode.software;
  } finally {
    for (final subscription in subscriptions) {
      await subscription.cancel();
    }
  }
}
