import 'package:meta/meta.dart';

/// One configured permission with its translations.
@immutable
class PermissionEntry {
  PermissionEntry({
    required this.configKey,
    required this.plistKey,
    required Map<String, String> translations,
    required this.defaultLocale,
  }) : translations = Map<String, String>.unmodifiable(translations) {
    if (this.translations.isEmpty) {
      throw ArgumentError.value(
        translations,
        'translations',
        'Permission "$configKey" needs at least one translation.',
      );
    }
    if (!this.translations.containsKey(defaultLocale)) {
      throw ArgumentError.value(
        defaultLocale,
        'defaultLocale',
        'Permission "$configKey" has no "$defaultLocale" translation.',
      );
    }
  }

  /// The key exactly as written in the YAML (alias or raw Apple key).
  final String configKey;

  /// The resolved Apple key, e.g. `NSCameraUsageDescription`.
  final String plistKey;

  /// Locale code (Xcode style, e.g. `en`, `pt-BR`) -> description text.
  final Map<String, String> translations;

  /// The locale whose text is written into `Info.plist` as the base value.
  ///
  /// Equal to the configured `default_locale` unless this permission does not
  /// translate it, in which case it is the permission's first locale.
  final String defaultLocale;

  /// The text written into `Info.plist`.
  String get defaultValue => translations[defaultLocale]!;

  @override
  bool operator ==(Object other) =>
      other is PermissionEntry &&
      other.configKey == configKey &&
      other.plistKey == plistKey &&
      other.defaultLocale == defaultLocale &&
      _mapEquals(other.translations, translations);

  @override
  int get hashCode => Object.hash(
        configKey,
        plistKey,
        defaultLocale,
        Object.hashAll(translations.entries.map((e) => '${e.key}=${e.value}')),
      );

  @override
  String toString() => 'PermissionEntry($configKey -> $plistKey, '
      'locales: ${translations.keys.join(', ')})';
}

/// The fully parsed and validated `ios_privacy_localizer` configuration.
@immutable
class LocalizerConfig {
  LocalizerConfig({
    required this.defaultLocale,
    required List<PermissionEntry> permissions,
    this.backup = false,
    this.skipPbxproj = false,
    List<String> warnings = const <String>[],
    this.source,
  })  : permissions = List<PermissionEntry>.unmodifiable(permissions),
        warnings = List<String>.unmodifiable(warnings),
        locales = List<String>.unmodifiable(_collectLocales(permissions)) {
    if (this.permissions.isEmpty) {
      throw ArgumentError.value(
        permissions,
        'permissions',
        'At least one permission is required.',
      );
    }
  }

  /// The configured (or inferred) default locale.
  final String defaultLocale;

  /// Every configured permission, in YAML order.
  final List<PermissionEntry> permissions;

  /// Whether `.bak` files are kept after a successful run.
  final bool backup;

  /// Whether `project.pbxproj` must be left untouched.
  final bool skipPbxproj;

  /// Non-fatal problems found while parsing (printed by the CLI).
  final List<String> warnings;

  /// Every locale used by at least one permission, in first-seen order.
  final List<String> locales;

  /// Path of the YAML file the configuration was read from, if any.
  final String? source;

  /// Apple key -> text written into `Info.plist`.
  Map<String, String> get infoPlistValues => Map<String, String>.unmodifiable(
        <String, String>{
          for (final permission in permissions)
            permission.plistKey: permission.defaultValue,
        },
      );

  /// Apple key -> text for the `<locale>.lproj/InfoPlist.strings` file.
  ///
  /// Permissions that do not translate [locale] are omitted; iOS then falls
  /// back to the `Info.plist` value for them.
  Map<String, String> translationsForLocale(String locale) =>
      Map<String, String>.unmodifiable(<String, String>{
        for (final permission in permissions)
          if (permission.translations.containsKey(locale))
            permission.plistKey: permission.translations[locale]!,
      });

  /// Returns a copy with the given overrides applied.
  LocalizerConfig copyWith({bool? backup, bool? skipPbxproj}) =>
      LocalizerConfig(
        defaultLocale: defaultLocale,
        permissions: permissions,
        backup: backup ?? this.backup,
        skipPbxproj: skipPbxproj ?? this.skipPbxproj,
        warnings: warnings,
        source: source,
      );

  static List<String> _collectLocales(List<PermissionEntry> permissions) {
    final seen = <String>{};
    for (final permission in permissions) {
      seen.addAll(permission.translations.keys);
    }
    return seen.toList();
  }

  @override
  String toString() => 'LocalizerConfig(defaultLocale: $defaultLocale, '
      'permissions: ${permissions.length}, locales: ${locales.join(', ')}, '
      'backup: $backup, skipPbxproj: $skipPbxproj)';
}

/// The outcome of applying an updater to the content of one file.
@immutable
class FileUpdateResult {
  const FileUpdateResult(this.content, this.changes);

  /// The new file content. Identical to the input when [changes] is empty.
  final String content;

  /// Human readable description of every semantic change, in order.
  final List<String> changes;

  /// Whether the file needs to be written.
  bool get hasChanges => changes.isNotEmpty;
}

bool _mapEquals(Map<String, String> a, Map<String, String> b) {
  if (a.length != b.length) {
    return false;
  }
  for (final entry in a.entries) {
    if (b[entry.key] != entry.value) {
      return false;
    }
  }
  return true;
}
