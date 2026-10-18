# Changelog

All notable changes to this project are documented in this file.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and the project adheres to [Semantic Versioning](https://semver.org/).

## 1.0.0

Initial release.

### Added

- `ios_privacy_localizer` CLI that localizes iOS permission usage descriptions
  (`NS*UsageDescription`) for Flutter apps.
- Configuration in `pubspec.yaml` (`ios_privacy_localizer:` section) or in a
  dedicated `ios_privacy_localizer.yaml`, with `default_locale`, `backup`,
  `skip_pbxproj` and `permissions`.
- 25 friendly aliases (`camera`, `photo_library`, `location_when_in_use`, ...)
  plus direct support for any raw `NS*UsageDescription` key, with "did you
  mean" suggestions for typos.
- Strict configuration validation: empty or whitespace-only descriptions,
  invalid or duplicate locale codes, duplicate permissions and wrong value
  types are rejected with line numbers.
- `Info.plist` updater (XML DOM) that adds or updates the default-locale
  descriptions and ensures `CFBundleAllowMixedLocalizations` is `true`,
  matching the file's indentation and line endings.
- Non-destructive `InfoPlist.strings` merger that keeps every existing entry
  and comment, including `CFBundleDisplayName` / `CFBundleName` written by
  `app_name_localizer`.
- Surgical `project.pbxproj` patcher with deterministic object IDs that
  reuses an existing `InfoPlist.strings` variant group, and adds the file
  references, the Runner group child, the Resources build file and the
  `knownRegions` entries. It only inserts text and never rewrites existing
  lines.
- Transaction engine: in-memory snapshots, `.bak` backups, atomic
  write-verify-rename, post-write validation and automatic rollback. The
  original file encoding (UTF-8, UTF-8 with BOM, UTF-16) is preserved.
- Validator using `plutil -lint` on macOS and a structural checker on every
  platform.
- CLI flags: `--path`, `--config`, `--dry-run`, `--backup`, `--restore`,
  `--validate` (for CI), `--skip-pbxproj`, `--[no-]color`, `--version`,
  `--help`, with documented exit codes.
