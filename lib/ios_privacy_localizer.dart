/// Safe, idempotent localization of iOS permission usage descriptions
/// (`NS*UsageDescription`) for Flutter projects.
///
/// Most users only need the CLI (`dart run ios_privacy_localizer`). This
/// library exposes the same building blocks for programmatic use.
library;

export 'src/exceptions/localizer_exception.dart';
export 'src/mapper/permission_mapper.dart';
export 'src/models/localizer_config.dart';
export 'src/parser/config_parser.dart';
export 'src/runner/localizer_logger.dart';
export 'src/runner/localizer_runner.dart';
export 'src/safety/plist_validator.dart';
export 'src/safety/text_codec.dart';
export 'src/safety/transaction_manager.dart';
export 'src/updaters/info_plist_updater.dart';
export 'src/updaters/pbxproj_updater.dart';
export 'src/updaters/strings_updater.dart';
export 'src/version.dart';
