// Runs ios_privacy_localizer programmatically.
//
// Usage (from your Flutter project root):
//   dart run ios_privacy_localizer_example.dart [--apply]
//
// Without --apply this is a dry run: every change is computed and printed,
// but no file is written.

import 'dart:io';

import 'package:ios_privacy_localizer/ios_privacy_localizer.dart';

void main(List<String> arguments) {
  final apply = arguments.contains('--apply');
  final runner = LocalizerRunner(projectRoot: Directory.current.path);

  try {
    final report = runner.run(dryRun: !apply);

    if (report.upToDate) {
      stdout.writeln('Nothing to do: the iOS project is already in sync.');
      return;
    }
    for (final change in report.changes) {
      stdout.writeln(
        '${apply ? 'Updated' : 'Would update'} ${change.displayPath} '
        '(${change.changes.length} change(s))',
      );
    }
  } on LocalizerException catch (e) {
    stderr.writeln(e);
    exitCode = e.exitCode;
  }
}
