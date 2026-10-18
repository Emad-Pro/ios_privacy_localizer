import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import '../exceptions/localizer_exception.dart';
import '../mapper/permission_mapper.dart';
import '../models/localizer_config.dart';

/// Locates, reads and validates the `ios_privacy_localizer` configuration.
///
/// Lookup order:
/// 1. the explicit [configPath] (`--config`), if given;
/// 2. `<projectRoot>/ios_privacy_localizer.yaml`;
/// 3. the `ios_privacy_localizer:` section of `<projectRoot>/pubspec.yaml`.
class ConfigParser {
  ConfigParser({required this.projectRoot, this.configPath});

  /// The Flutter project root.
  final String projectRoot;

  /// Optional custom configuration file (absolute, or relative to the
  /// current directory or to [projectRoot]).
  final String? configPath;

  /// The YAML section name (also accepted as a wrapper in the dedicated file).
  static const String sectionKey = 'ios_privacy_localizer';

  /// Name of the dedicated configuration file.
  static const String dedicatedFileName = 'ios_privacy_localizer.yaml';

  /// Accepted locale shape (after `_` -> `-` normalization).
  static final RegExp localePattern =
      RegExp(r'^[a-zA-Z]{2,3}(-[a-zA-Z0-9]{2,8})*$');

  static const Set<String> _knownOptions = <String>{
    'default_locale',
    'backup',
    'skip_pbxproj',
    'permissions',
  };

  /// Finds the configuration source, parses and validates it.
  LocalizerConfig load() {
    final (file, isPubspec) = _locateSource();
    final String content;
    try {
      content = file.readAsStringSync();
    } on FileSystemException catch (e) {
      throw LocalizerFileException(
        'Unable to read ${file.path}: ${e.message}',
        path: file.path,
      );
    } on FormatException catch (e) {
      throw LocalizerConfigException(
        '${file.path} is not valid UTF-8: ${e.message}',
      );
    }
    return parseString(content, sourceLabel: file.path, fromPubspec: isPubspec);
  }

  (File, bool) _locateSource() {
    final custom = configPath;
    if (custom != null) {
      final candidates = p.isAbsolute(custom)
          ? <String>[custom]
          : <String>[p.absolute(custom), p.join(projectRoot, custom)];
      for (final candidate in candidates) {
        final file = File(p.normalize(candidate));
        if (file.existsSync()) {
          return (file, p.basename(candidate) == 'pubspec.yaml');
        }
      }
      throw LocalizerFileException(
        'Configuration file not found: $custom',
        path: custom,
        isMissing: true,
      );
    }

    final dedicated = File(p.join(projectRoot, dedicatedFileName));
    if (dedicated.existsSync()) {
      return (dedicated, false);
    }
    final pubspec = File(p.join(projectRoot, 'pubspec.yaml'));
    if (pubspec.existsSync()) {
      return (pubspec, true);
    }
    throw LocalizerFileException(
      'No configuration found in $projectRoot.',
      isMissing: true,
      hint: 'Create $dedicatedFileName or add an `$sectionKey:` section to '
          'pubspec.yaml, or pass --path / --config.',
    );
  }

  /// Parses YAML [content]. [sourceLabel] is used in error messages.
  ///
  /// When [fromPubspec] is `true` the `ios_privacy_localizer:` section is
  /// mandatory; otherwise the document may be either wrapped in that section
  /// or be the section itself.
  static LocalizerConfig parseString(
    String content, {
    String sourceLabel = 'configuration',
    bool fromPubspec = false,
  }) {
    final Object? document;
    try {
      document = loadYaml(content);
    } on YamlException catch (e) {
      throw LocalizerConfigException(
        'Invalid YAML in $sourceLabel (line ${e.span?.start.line == null ? '?' : e.span!.start.line + 1}): ${e.message}',
      );
    }

    if (document is! YamlMap) {
      throw LocalizerConfigException(
        '$sourceLabel must contain a YAML map.',
        hint: _exampleHint,
      );
    }

    final YamlNode? sectionNode;
    if (document.containsKey(sectionKey)) {
      sectionNode = document.nodes[sectionKey];
    } else if (fromPubspec) {
      throw LocalizerConfigException(
        'No `$sectionKey:` section found in $sourceLabel.',
        hint: _exampleHint,
      );
    } else {
      sectionNode = document;
    }

    if (sectionNode is! YamlMap) {
      throw LocalizerConfigException(
        'The `$sectionKey` section in $sourceLabel must be a map.',
        hint: _exampleHint,
      );
    }
    return _parseSection(sectionNode, sourceLabel);
  }

  /// Converts `en_US` to `en-US` and validates the result.
  static String normalizeLocale(String raw, {String? context}) {
    final normalized = raw.trim().replaceAll('_', '-');
    if (!localePattern.hasMatch(normalized)) {
      throw LocalizerConfigException(
        'Invalid locale code "$raw"${context == null ? '' : ' ($context)'}.',
        hint: 'Use Apple/BCP-47 codes such as en, ar, fr, pt-BR or zh-Hans.',
      );
    }
    return normalized;
  }

  static LocalizerConfig _parseSection(YamlMap section, String sourceLabel) {
    final warnings = <String>[];

    for (final key in section.keys) {
      if (!_knownOptions.contains(key)) {
        warnings.add('Unknown option "$key" in $sourceLabel was ignored.');
      }
    }

    final backup = _readBool(section, 'backup', sourceLabel);
    final skipPbxproj = _readBool(section, 'skip_pbxproj', sourceLabel);

    final permissionsNode = section.nodes['permissions'];
    if (permissionsNode == null || permissionsNode.value == null) {
      throw LocalizerConfigException(
        'The `permissions` map is missing in $sourceLabel.',
        hint: _exampleHint,
      );
    }
    if (permissionsNode is! YamlMap) {
      throw LocalizerConfigException(
        '`permissions` must be a map in $sourceLabel (${_where(permissionsNode)}).',
        hint: _exampleHint,
      );
    }
    if (permissionsNode.isEmpty) {
      throw LocalizerConfigException(
        'The `permissions` map in $sourceLabel is empty.',
        hint: _exampleHint,
      );
    }

    final rawPermissions = <_RawPermission>[];
    final configKeyByPlistKey = <String, String>{};

    for (final entry in permissionsNode.nodes.entries) {
      final keyNode = entry.key;
      final keyValue = keyNode is YamlNode ? keyNode.value : keyNode;
      final location = keyNode is YamlNode ? _where(keyNode) : 'unknown line';
      if (keyValue is! String || keyValue.trim().isEmpty) {
        throw LocalizerConfigException(
          'Permission names must be non-empty strings (found "$keyValue" at $location).',
        );
      }
      final configKey = keyValue.trim();

      final String plistKey;
      try {
        plistKey = PermissionMapper.resolve(configKey);
      } on LocalizerConfigException catch (e) {
        throw LocalizerConfigException(
          '${e.message} ($sourceLabel, $location)',
          hint: e.hint,
        );
      }

      final previous = configKeyByPlistKey[plistKey];
      if (previous != null) {
        throw LocalizerConfigException(
          'Permissions "$previous" and "$configKey" both resolve to $plistKey ($location).',
          hint: 'Keep only one of them.',
        );
      }
      configKeyByPlistKey[plistKey] = configKey;

      final valueNode = entry.value;
      if (valueNode is! YamlMap || valueNode.isEmpty) {
        throw LocalizerConfigException(
          'Permission "$configKey" must define at least one locale translation ($location).',
          hint:
              'Example:\n  $configKey:\n    en: "Why your app needs this access."',
        );
      }

      final translations = <String, String>{};
      for (final translation in valueNode.nodes.entries) {
        final localeNode = translation.key;
        final localeValue =
            localeNode is YamlNode ? localeNode.value : localeNode;
        final localeLocation =
            localeNode is YamlNode ? _where(localeNode) : location;
        if (localeValue is! String) {
          throw LocalizerConfigException(
            'Locale codes of "$configKey" must be strings (found "$localeValue" at $localeLocation).',
          );
        }
        final locale = normalizeLocale(
          localeValue,
          context: 'permission "$configKey", $localeLocation',
        );
        if (translations.containsKey(locale)) {
          throw LocalizerConfigException(
            'Permission "$configKey" defines locale "$locale" more than once ($localeLocation).',
          );
        }

        final text = translation.value.value;
        if (text is! String) {
          throw LocalizerConfigException(
            'The "$locale" translation of "$configKey" must be a string ($localeLocation).',
            hint: 'Wrap the text in quotes.',
          );
        }
        final trimmed = text.trim();
        if (trimmed.isEmpty) {
          throw LocalizerConfigException(
            'The "$locale" translation of "$configKey" is empty ($localeLocation).',
            hint: 'Apple rejects apps with blank usage descriptions. '
                'Explain clearly why the permission is needed.',
          );
        }
        translations[locale] = trimmed;
      }

      rawPermissions.add(_RawPermission(configKey, plistKey, translations));
    }

    final allLocales = <String>{
      for (final permission in rawPermissions) ...permission.translations.keys,
    };

    final defaultNode = section.nodes['default_locale'];
    String defaultLocale;
    if (defaultNode == null || defaultNode.value == null) {
      defaultLocale = allLocales.first;
      warnings.add(
        '`default_locale` is not set; using "$defaultLocale" (the first '
        'configured locale) for Info.plist values.',
      );
    } else {
      final value = defaultNode.value;
      if (value is! String) {
        throw LocalizerConfigException(
          '`default_locale` must be a string in $sourceLabel (${_where(defaultNode)}).',
        );
      }
      defaultLocale = normalizeLocale(value, context: '`default_locale`');
      if (!allLocales.contains(defaultLocale)) {
        final fallback = allLocales.first;
        warnings.add(
          'No permission defines a "$defaultLocale" translation; falling back '
          'to "$fallback" as the default locale.',
        );
        defaultLocale = fallback;
      }
    }

    final permissions = <PermissionEntry>[];
    for (final raw in rawPermissions) {
      var permissionDefault = defaultLocale;
      if (!raw.translations.containsKey(defaultLocale)) {
        permissionDefault = raw.translations.keys.first;
        warnings.add(
          'Permission "${raw.configKey}" has no "$defaultLocale" translation; '
          'Info.plist will use its "$permissionDefault" text instead.',
        );
      }
      permissions.add(
        PermissionEntry(
          configKey: raw.configKey,
          plistKey: raw.plistKey,
          translations: raw.translations,
          defaultLocale: permissionDefault,
        ),
      );
    }

    return LocalizerConfig(
      defaultLocale: defaultLocale,
      permissions: permissions,
      backup: backup,
      skipPbxproj: skipPbxproj,
      warnings: warnings,
      source: sourceLabel,
    );
  }

  static bool _readBool(YamlMap section, String key, String sourceLabel) {
    final node = section.nodes[key];
    if (node == null || node.value == null) {
      return false;
    }
    final value = node.value;
    if (value is! bool) {
      throw LocalizerConfigException(
        '`$key` must be true or false in $sourceLabel (${_where(node)}).',
      );
    }
    return value;
  }

  static String _where(YamlNode node) => 'line ${node.span.start.line + 1}';

  static const String _exampleHint = '''Example:
ios_privacy_localizer:
  default_locale: en
  permissions:
    camera:
      en: "We need camera access to scan QR codes."
      ar: "نحتاج إلى صلاحية الكاميرا لمسح رموز QR."''';
}

class _RawPermission {
  _RawPermission(this.configKey, this.plistKey, this.translations);

  final String configKey;
  final String plistKey;
  final Map<String, String> translations;
}
