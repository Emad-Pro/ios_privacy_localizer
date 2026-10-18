import 'package:ios_privacy_localizer/ios_privacy_localizer.dart';
import 'package:test/test.dart';

void main() {
  group('PermissionMapper.resolve', () {
    test('maps every documented alias to its Apple key', () {
      const expected = <String, String>{
        'camera': 'NSCameraUsageDescription',
        'microphone': 'NSMicrophoneUsageDescription',
        'photo_library': 'NSPhotoLibraryUsageDescription',
        'photo_library_add': 'NSPhotoLibraryAddUsageDescription',
        'location_when_in_use': 'NSLocationWhenInUseUsageDescription',
        'location_always': 'NSLocationAlwaysAndWhenInUseUsageDescription',
        'location_always_legacy': 'NSLocationAlwaysUsageDescription',
        'contacts': 'NSContactsUsageDescription',
        'calendars': 'NSCalendarsUsageDescription',
        'calendars_full_access': 'NSCalendarsFullAccessUsageDescription',
        'calendars_write_only': 'NSCalendarsWriteOnlyAccessUsageDescription',
        'reminders': 'NSRemindersUsageDescription',
        'reminders_full_access': 'NSRemindersFullAccessUsageDescription',
        'face_id': 'NSFaceIDUsageDescription',
        'bluetooth': 'NSBluetoothAlwaysUsageDescription',
        'bluetooth_peripheral': 'NSBluetoothPeripheralUsageDescription',
        'tracking': 'NSUserTrackingUsageDescription',
        'speech_recognition': 'NSSpeechRecognitionUsageDescription',
        'motion': 'NSMotionUsageDescription',
        'health_share': 'NSHealthShareUsageDescription',
        'health_update': 'NSHealthUpdateUsageDescription',
        'apple_music': 'NSAppleMusicUsageDescription',
        'local_network': 'NSLocalNetworkUsageDescription',
        'nearby_interaction': 'NSNearbyInteractionUsageDescription',
        'siri': 'NSSiriUsageDescription',
      };
      expect(PermissionMapper.aliases, hasLength(25));
      expected.forEach((alias, key) {
        expect(PermissionMapper.resolve(alias), key, reason: alias);
      });
    });

    test('every alias resolves to a valid raw key', () {
      for (final key in PermissionMapper.aliases.values) {
        expect(PermissionMapper.isRawKey(key), isTrue, reason: key);
      }
    });

    test('accepts raw NS*UsageDescription keys directly', () {
      expect(
        PermissionMapper.resolve('NSFocusStatusUsageDescription'),
        'NSFocusStatusUsageDescription',
      );
      expect(
        PermissionMapper.resolve('NSCameraUsageDescription'),
        'NSCameraUsageDescription',
      );
    });

    test('rejects unknown keys with a close suggestion', () {
      expect(
        () => PermissionMapper.resolve('camra'),
        throwsA(
          isA<LocalizerConfigException>()
              .having((e) => e.message, 'message', contains('camra'))
              .having((e) => e.hint, 'hint', contains('"camera"')),
        ),
      );
      expect(
        () => PermissionMapper.resolve('NSCameraUsageDescriptio'),
        throwsA(
          isA<LocalizerConfigException>().having(
            (e) => e.hint,
            'hint',
            contains('NSCameraUsageDescription'),
          ),
        ),
      );
    });

    test('rejects keys that only look similar to Apple keys', () {
      for (final key in <String>[
        'NSUsageDescription',
        'NS Camera UsageDescription',
        'CFBundleDisplayName',
        '',
      ]) {
        expect(
          () => PermissionMapper.resolve(key),
          throwsA(isA<LocalizerConfigException>()),
          reason: key,
        );
      }
    });
  });

  group('PermissionMapper.suggest', () {
    test('handles case, separators and prefixes', () {
      expect(PermissionMapper.suggest('Camera'), 'camera');
      expect(PermissionMapper.suggest('photo-library'), 'photo_library');
      expect(PermissionMapper.suggest('photo'), 'photo_library');
      expect(PermissionMapper.suggest('faceid'), 'face_id');
    });

    test('returns null when nothing is close', () {
      expect(PermissionMapper.suggest('completely_unrelated_thing'), isNull);
    });
  });

  test('aliasFor is the reverse lookup', () {
    expect(PermissionMapper.aliasFor('NSCameraUsageDescription'), 'camera');
    expect(PermissionMapper.aliasFor('NSFocusStatusUsageDescription'), isNull);
  });
}
