import '../exceptions/localizer_exception.dart';

/// Maps friendly `snake_case` permission aliases to the exact Apple
/// `Info.plist` usage-description keys, and back.
abstract final class PermissionMapper {
  /// Friendly alias -> Apple `Info.plist` key.
  static const Map<String, String> aliases = <String, String>{
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

  /// Shape of a raw Apple usage-description key, e.g.
  /// `NSFocusStatusUsageDescription`.
  static final RegExp rawKeyPattern =
      RegExp(r'^NS[A-Za-z0-9]+UsageDescription$');

  static final Map<String, String> _aliasByKey = <String, String>{
    for (final entry in aliases.entries) entry.value: entry.key,
  };

  /// Whether [key] is one of the supported friendly aliases.
  static bool isAlias(String key) => aliases.containsKey(key);

  /// Whether [key] looks like a raw Apple usage-description key.
  static bool isRawKey(String key) => rawKeyPattern.hasMatch(key);

  /// The friendly alias for an Apple [plistKey], or `null` if none exists.
  static String? aliasFor(String plistKey) => _aliasByKey[plistKey];

  /// Resolves [key] (alias or raw Apple key) to the `Info.plist` key.
  ///
  /// Throws a [LocalizerConfigException] with the closest valid suggestion
  /// when [key] is neither a known alias nor a raw `NS*UsageDescription` key.
  static String resolve(String key) {
    final mapped = aliases[key];
    if (mapped != null) {
      return mapped;
    }
    if (isRawKey(key)) {
      return key;
    }
    final suggestion = suggest(key);
    throw LocalizerConfigException(
      'Unknown permission "$key".',
      hint: suggestion != null
          ? 'Did you mean "$suggestion"?'
          : 'Use a supported alias (for example ${aliases.keys.take(6).join(', ')}) '
              'or a raw Apple key such as NSCameraUsageDescription.',
    );
  }

  /// Returns the alias or Apple key closest to [input], or `null` when
  /// nothing is reasonably close.
  static String? suggest(String input) {
    final needle =
        input.trim().toLowerCase().replaceAll(RegExp(r'[\s\-]+'), '_');
    if (needle.isEmpty) {
      return null;
    }

    for (final alias in aliases.keys) {
      if (needle.length >= 3 && alias.startsWith(needle)) {
        return alias;
      }
    }

    String? best;
    var bestDistance = 1 << 30;
    for (final candidate in <String>[...aliases.keys, ...aliases.values]) {
      final distance = _levenshtein(needle, candidate.toLowerCase());
      if (distance < bestDistance) {
        bestDistance = distance;
        best = candidate;
      }
    }

    final threshold = needle.length ~/ 3 < 2 ? 2 : needle.length ~/ 3;
    return bestDistance <= threshold ? best : null;
  }

  static int _levenshtein(String a, String b) {
    if (a == b) {
      return 0;
    }
    if (a.isEmpty) {
      return b.length;
    }
    if (b.isEmpty) {
      return a.length;
    }
    var previous = List<int>.generate(b.length + 1, (i) => i);
    var current = List<int>.filled(b.length + 1, 0);
    for (var i = 1; i <= a.length; i++) {
      current[0] = i;
      for (var j = 1; j <= b.length; j++) {
        final cost = a.codeUnitAt(i - 1) == b.codeUnitAt(j - 1) ? 0 : 1;
        final deletion = previous[j] + 1;
        final insertion = current[j - 1] + 1;
        final substitution = previous[j - 1] + cost;
        var best = deletion < insertion ? deletion : insertion;
        if (substitution < best) {
          best = substitution;
        }
        current[j] = best;
      }
      final swap = previous;
      previous = current;
      current = swap;
    }
    return previous[b.length];
  }
}
