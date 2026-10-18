# ios_privacy_localizer

![ios_privacy_localizer: localize iOS permission prompts safely](https://raw.githubusercontent.com/Emad-Pro/ios_privacy_localizer/main/doc/banner.png)

[![pub package](https://img.shields.io/pub/v/ios_privacy_localizer.svg)](https://pub.dev/packages/ios_privacy_localizer)
[![Dart SDK](https://img.shields.io/badge/dart-%3E%3D3.0.0-0175C2.svg?logo=dart)](https://dart.dev)
[![Platform](https://img.shields.io/badge/platform-iOS-lightgrey.svg?logo=apple)](https://developer.apple.com/documentation/bundleresources/information_property_list/protected_resources)
[![Style: lints](https://img.shields.io/badge/style-lints-40c4ff.svg)](https://pub.dev/packages/lints)
[![License: MIT](https://img.shields.io/badge/license-MIT-purple.svg)](LICENSE)

**Localize iOS permission dialogs (`NS*UsageDescription`) in your Flutter app
from one YAML block, without the risk of corrupting your Xcode project.**

iOS shows the text of `NSCameraUsageDescription`,
`NSLocationWhenInUseUsageDescription` and similar keys in the system
permission prompt. To show that text in Arabic, French or any other language,
Xcode needs:

1. a base value in `ios/Runner/Info.plist`,
2. one `ios/Runner/<locale>.lproj/InfoPlist.strings` file per language, and
3. a `PBXVariantGroup` plus file references, a build file and `knownRegions`
   entries in `ios/Runner.xcodeproj/project.pbxproj`.

`ios_privacy_localizer` sets up all three for you, safely, every time you run
it.

> Created by **Emad Younis** (عماد يونس), author of
> [`app_name_localizer`](https://pub.dev/packages/app_name_localizer). The two
> tools are designed to be used together.

---

## Contents

- [Features](#features)
- [Installation](#installation)
- [Configuration](#configuration)
- [Usage](#usage)
- [CLI reference](#cli-reference)
- [Supported permission aliases](#supported-permission-aliases)
- [Safety guarantees](#safety-guarantees)
- [Using it with app_name_localizer](#using-it-with-app_name_localizer)
- [CI/CD](#cicd)
- [What gets changed](#what-gets-changed)
- [Troubleshooting](#troubleshooting)

## Features

- **One source of truth:** every permission and translation lives in
  `pubspec.yaml` or `ios_privacy_localizer.yaml`.
- **Friendly aliases** such as `camera` and `photo_library`, plus any raw
  Apple key such as `NSFocusStatusUsageDescription`.
- **Edits never destroy existing content:** existing keys, values, comments
  and formatting are preserved, and nothing is ever deleted.
- **Idempotent:** a second run changes nothing, byte for byte.
- **Atomic:** files are backed up, written, validated, and rolled back if
  anything fails.
- **Deterministic `project.pbxproj` patching:** object IDs are stable, so
  diffs stay small and identical on every machine.
- **CI friendly:** `--validate` exits with `1` when the project is out of
  sync.
- **Dry run:** use `--dry-run` to see every change before anything is written.

## Installation

Add the package as a dev dependency of your Flutter app:

```bash
dart pub add --dev ios_privacy_localizer
```

Or activate it globally:

```bash
dart pub global activate ios_privacy_localizer
```

## Configuration

Add an `ios_privacy_localizer:` section to your app's `pubspec.yaml`:

```yaml
ios_privacy_localizer:
  default_locale: en
  backup: false # true keeps the .bak files after a successful run
  skip_pbxproj: false # true only updates Info.plist and .strings files
  permissions:
    camera: # Friendly alias, resolves to NSCameraUsageDescription
      en: "We need camera access to scan QR codes and take profile photos."
      ar: "نحتاج إلى صلاحية الكاميرا لمسح رموز QR والتقاط الصورة الشخصية."
    photo_library: # Resolves to NSPhotoLibraryUsageDescription
      en: "We need photo library access to let you attach receipts."
      ar: "نحتاج إلى الوصول لمعرض الصور لإرفاق الإيصالات."
    NSLocationWhenInUseUsageDescription: # Raw Apple keys work too
      en: "We use your location to show nearby branches."
      ar: "نستخدم موقعك الحالي لعرض الفروع القريبة منك."
```

You can also put the same content in a dedicated
`ios_privacy_localizer.yaml` at the project root. The top-level
`ios_privacy_localizer:` key is optional in that file. When both files exist,
the dedicated file wins.

### Options

| Key | Type | Default | Description |
| --- | --- | --- | --- |
| `default_locale` | string | first configured locale | Locale whose text is written into `Info.plist`, which iOS uses as the fallback. |
| `backup` | bool | `false` | Keep `<file>.bak` next to every modified file after a successful run. |
| `skip_pbxproj` | bool | `false` | Never touch `project.pbxproj`. |
| `permissions` | map | required | Alias or Apple key, mapped to a map of locale and text. |

### Validation rules

The tool refuses to run when:

- `permissions` is missing or empty;
- a permission has no translation;
- a translation is empty or whitespace-only (App Review rejects blank usage
  descriptions);
- a locale code does not match `^[a-zA-Z]{2,3}(-[a-zA-Z0-9]{2,8})*$`.
  Examples: `en`, `ar`, `fr`, `pt-BR`, `zh-Hans`. `en_US` is normalized to
  `en-US`;
- a permission name is unknown. You get a suggestion such as
  *Did you mean "camera"?*;
- two entries resolve to the same Apple key, for example `camera` and
  `NSCameraUsageDescription`.

If a permission has no `default_locale` translation, its first translation is
used for `Info.plist` and a warning is printed.

## Usage

Run the tool from your Flutter project root:

```bash
# Preview every change without touching any file
dart run ios_privacy_localizer --dry-run

# Apply the changes
dart run ios_privacy_localizer

# Check whether the project is in sync (CI)
dart run ios_privacy_localizer --validate
```

Example output:

```text
╔══════════════════════════════════════════════════════════════╗
║  ios_privacy_localizer v1.0.1 - Created by Emad Younis       ║
║  Safe iOS Permission & InfoPlist.strings Localization Tool   ║
╚══════════════════════════════════════════════════════════════╝

▸ Configuration: pubspec.yaml
  3 permission(s) · locales: en, ar · default: en

▸ Changes:
  ✎ ios/Runner/Info.plist
      • Add NSCameraUsageDescription
      • Add NSPhotoLibraryUsageDescription
      • Add NSLocationWhenInUseUsageDescription
      • Add CFBundleAllowMixedLocalizations = true
  ✎ ios/Runner/en.lproj/InfoPlist.strings
      • Add "NSCameraUsageDescription"
      ...
  ✚ ios/Runner/ar.lproj/InfoPlist.strings (new file)
      ...
  ✎ ios/Runner.xcodeproj/project.pbxproj
      • Create PBXVariantGroup "InfoPlist.strings" (D74333CC50AC1CA403A7EA58)
      ...

✔ Validated 4 file(s) (structure + plutil -lint).
✔ Done. 4 file(s) updated safely.
```

Then rebuild the app (`flutter run`). Permission prompts appear in the
device's language.

## CLI reference

| Flag | Short | Description |
| --- | --- | --- |
| `--path <dir>` | `-p` | Flutter project root (default: current directory). |
| `--config <file>` | `-c` | Custom YAML file, relative to the current directory or the project root. |
| `--dry-run` | | Parse the config, compute every change and print a summary. Writes nothing. |
| `--backup` | | Keep the `.bak` files after a successful run. Same as `backup: true`. |
| `--restore` | | Restore `Info.plist`, `project.pbxproj` and every `InfoPlist.strings` from their `.bak` files. Works with `--dry-run`. |
| `--validate` | | Check that every configured permission and locale is present in `Info.plist`, the `.strings` files and `project.pbxproj`. Writes nothing. |
| `--skip-pbxproj` | | Only update `Info.plist` and `.lproj/InfoPlist.strings`. Same as `skip_pbxproj: true`. |
| `--[no-]color` | | Enable or disable ANSI colors. Colors are also disabled when `NO_COLOR` is set. |
| `--version` | | Print the version. |
| `--help` | `-h` | Print usage. |

### Exit codes

| Code | Meaning |
| --- | --- |
| `0` | Success, or the project is in sync for `--validate`. |
| `1` | `--validate`: the project is out of sync. |
| `64` | Invalid command line usage. |
| `65` | Invalid configuration or native project file. Nothing was written. |
| `66` | A required file (config, `Info.plist`, `project.pbxproj`, backups) is missing. |
| `70` | Validation failed after writing. Every change was rolled back. |
| `74` | A file could not be read or written. |

## Supported permission aliases

| Alias | `Info.plist` key |
| --- | --- |
| `camera` | `NSCameraUsageDescription` |
| `microphone` | `NSMicrophoneUsageDescription` |
| `photo_library` | `NSPhotoLibraryUsageDescription` |
| `photo_library_add` | `NSPhotoLibraryAddUsageDescription` |
| `location_when_in_use` | `NSLocationWhenInUseUsageDescription` |
| `location_always` | `NSLocationAlwaysAndWhenInUseUsageDescription` |
| `location_always_legacy` | `NSLocationAlwaysUsageDescription` |
| `contacts` | `NSContactsUsageDescription` |
| `calendars` | `NSCalendarsUsageDescription` |
| `calendars_full_access` | `NSCalendarsFullAccessUsageDescription` |
| `calendars_write_only` | `NSCalendarsWriteOnlyAccessUsageDescription` |
| `reminders` | `NSRemindersUsageDescription` |
| `reminders_full_access` | `NSRemindersFullAccessUsageDescription` |
| `face_id` | `NSFaceIDUsageDescription` |
| `bluetooth` | `NSBluetoothAlwaysUsageDescription` |
| `bluetooth_peripheral` | `NSBluetoothPeripheralUsageDescription` |
| `tracking` | `NSUserTrackingUsageDescription` |
| `speech_recognition` | `NSSpeechRecognitionUsageDescription` |
| `motion` | `NSMotionUsageDescription` |
| `health_share` | `NSHealthShareUsageDescription` |
| `health_update` | `NSHealthUpdateUsageDescription` |
| `apple_music` | `NSAppleMusicUsageDescription` |
| `local_network` | `NSLocalNetworkUsageDescription` |
| `nearby_interaction` | `NSNearbyInteractionUsageDescription` |
| `siri` | `NSSiriUsageDescription` |

Any other key that matches `NS…UsageDescription`, such as
`NSFocusStatusUsageDescription`, can be used directly.

## Safety guarantees

The tool edits files that can break your build if they are corrupted. These
rules are enforced by design and covered by tests:

1. **Plan in memory first.** Every new file content is computed before any
   file is opened for writing. A parse error in any file aborts the run with
   zero changes.
2. **Pre-flight validation.** `Info.plist` and `project.pbxproj` must already
   be valid. If they are not, the tool stops before changing anything.
3. **Snapshots and backups.** The exact original bytes of every file are kept
   in memory and written to `<file>.bak` before the first modification.
   Existing `.bak` files from earlier runs are never lost.
4. **Atomic writes.** Content is written to a temporary file, read back,
   compared byte for byte and only then renamed over the target. No file is
   ever left half written.
5. **Post-write validation.** Every modified file is validated with
   `plutil -lint` on macOS and a structural checker on all platforms. The
   checker covers XML structure, `"KEY" = "VALUE";` syntax, and balanced
   braces and parentheses outside strings. Any failure **rolls back
   everything**: originals are restored, new files and folders are deleted,
   and temporary `.bak` files are removed.
6. **Only adds, never removes.**
   - `Info.plist` is edited through an XML DOM. Only the configured keys and
     `CFBundleAllowMixedLocalizations` are touched. Indentation and line
     endings are matched.
   - `InfoPlist.strings` entries and comments you did not configure are kept
     in place. Keys are never removed.
   - `project.pbxproj` is fully parsed, but edited only by inserting new
     lines at exact positions. No existing line is rewritten.
7. **Idempotent and deterministic.** Object IDs come from
   `md5("ios_privacy_localizer:<seed>")`, so repeated runs produce identical
   files, and a second run reports *Everything is already up to date*.
8. **Encoding-preserving.** Files stored as UTF-8, UTF-8 with BOM, or UTF-16
   (common for older Xcode `.strings` files) are written back in the same
   encoding. CRLF line endings are preserved.
9. **Interrupt-safe.** Ctrl+C is deferred while files are being written, so
   the transaction always finishes or rolls back first.

## Using it with app_name_localizer

[`app_name_localizer`](https://pub.dev/packages/app_name_localizer) writes
`CFBundleDisplayName` and `CFBundleName` into the same
`<locale>.lproj/InfoPlist.strings` files. `ios_privacy_localizer` is built to
share those files:

- Existing entries are preserved exactly, and new permission keys are
  appended below them:

  ```text
  /* Generated & Managed by ios_privacy_localizer - Created by Emad Younis */
  "CFBundleDisplayName" = "تطبيقي";
  "CFBundleName" = "تطبيقي";
  "NSCameraUsageDescription" = "نحتاج إلى صلاحية الكاميرا لمسح رموز QR والتقاط الصورة الشخصية.";
  ```

- If an `InfoPlist.strings` variant group already exists in
  `project.pbxproj`, created by `app_name_localizer` or by Xcode, the tool
  **reuses it**. Missing locales are added to it, and no duplicate group,
  file reference or build file is created.
- The tools can run in either order, as many times as you like.

Recommended order in a setup script:

```bash
dart run app_name_localizer
dart run ios_privacy_localizer
```

## CI/CD

Fail the build when someone adds a permission to the YAML but forgets to run
the tool:

```yaml
# .github/workflows/ios.yml
- name: Check iOS permission localizations
  run: dart run ios_privacy_localizer --validate
```

`--validate` exits with `0` when everything is in sync and `1` otherwise. It
lists every missing key, file and pbxproj entry.

## What gets changed

| File | Change |
| --- | --- |
| `ios/Runner/Info.plist` | Adds or updates each `NS*UsageDescription` with the `default_locale` text, and sets `CFBundleAllowMixedLocalizations` to `true`. |
| `ios/Runner/<locale>.lproj/InfoPlist.strings` | Creates the file if needed, then adds or updates the configured keys for that locale. |
| `ios/Runner.xcodeproj/project.pbxproj` | Adds `PBXFileReference` entries per locale, the `InfoPlist.strings` `PBXVariantGroup` (if missing), its entry in the `Runner` group, a `PBXBuildFile` in the Runner *Copy Bundle Resources* phase, and the locales in `knownRegions`. |

Commit these files. Add `*.bak` to your `.gitignore` if you use
`--backup`.

## Troubleshooting

**"Info.plist is a binary property list"**: convert it once with
`plutil -convert xml1 ios/Runner/Info.plist`.

**"the Runner PBXGroup could not be found"**: the project does not follow the
standard Flutter layout. This also happens with Xcode 16 folder-synchronized
groups. Run with `--skip-pbxproj` and add `InfoPlist.strings` once in Xcode
(*File, New, File, Strings File*, then *Localize…*). Later runs only need to
update the `.strings` files.

**"... is already invalid before any modification"**: the file was broken
before the tool touched it. Restore it from version control (or with
`--restore` if you kept backups) and run again.

**Restore limitations**: `--restore` restores files that have a `.bak`. It does
not delete `.lproj` folders or `.strings` files created by a run. Use
`git checkout` / `git clean` for that.

**The prompt is still in English**: make sure the device or simulator
language is set to one of your locales, then do a clean build. iOS caches
`InfoPlist.strings` aggressively; deleting the app from the simulator helps.
