# ios_privacy_localizer example

## 1. Add the package

```bash
dart pub add --dev ios_privacy_localizer
```

## 2. Configure your permissions

Add this to your Flutter app's `pubspec.yaml`, or put it in a separate
`ios_privacy_localizer.yaml` at the project root:

```yaml
ios_privacy_localizer:
  default_locale: en
  permissions:
    camera:
      en: "We need camera access to scan QR codes and take profile photos."
      ar: "نحتاج إلى صلاحية الكاميرا لمسح رموز QR والتقاط الصورة الشخصية."
    photo_library:
      en: "We need photo library access to let you attach receipts."
      ar: "نحتاج إلى الوصول لمعرض الصور لإرفاق الإيصالات."
    location_when_in_use:
      en: "We use your location to show nearby branches."
      ar: "نستخدم موقعك الحالي لعرض الفروع القريبة منك."
```

## 3. Run it

```bash
# Preview every change without writing anything
dart run ios_privacy_localizer --dry-run

# Apply the changes
dart run ios_privacy_localizer

# In CI: exit code 1 when the project is out of sync
dart run ios_privacy_localizer --validate
```

## Result

`ios/Runner/ar.lproj/InfoPlist.strings`:

```text
/* Generated & Managed by ios_privacy_localizer - Created by Emad Younis */
"NSCameraUsageDescription" = "نحتاج إلى صلاحية الكاميرا لمسح رموز QR والتقاط الصورة الشخصية.";
"NSPhotoLibraryUsageDescription" = "نحتاج إلى الوصول لمعرض الصور لإرفاق الإيصالات.";
"NSLocationWhenInUseUsageDescription" = "نستخدم موقعك الحالي لعرض الفروع القريبة منك.";
```

`Info.plist` gets the `default_locale` texts and
`CFBundleAllowMixedLocalizations`. `project.pbxproj` gets the
`InfoPlist.strings` variant group, the file references, the Resources build
file and `knownRegions`.

## Programmatic use

The same workflow is available from Dart. See
[`ios_privacy_localizer_example.dart`](ios_privacy_localizer_example.dart).
