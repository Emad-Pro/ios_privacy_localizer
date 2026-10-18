import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../exceptions/localizer_exception.dart';

/// Text encodings found in iOS project files.
///
/// Xcode historically wrote `.strings` files as UTF-16, so the encoding of an
/// existing file is detected from its byte-order mark and preserved on write.
enum TextEncodingKind {
  /// UTF-8 without a byte-order mark (the default for new files).
  utf8,

  /// UTF-8 with a leading `EF BB BF` byte-order mark.
  utf8WithBom,

  /// UTF-16 little endian with a `FF FE` byte-order mark.
  utf16le,

  /// UTF-16 big endian with a `FE FF` byte-order mark.
  utf16be,
}

/// Decoded file text together with the encoding it was stored in.
@immutable
class DecodedText {
  /// Creates decoded [text] that was stored as [encoding].
  const DecodedText(this.text, this.encoding);

  /// The text, without any byte-order mark.
  final String text;

  /// The encoding detected on disk.
  final TextEncodingKind encoding;
}

/// Lossless byte <-> text conversion for project files.
abstract final class TextFileCodec {
  /// Detects the encoding of [bytes] from its byte-order mark.
  static TextEncodingKind detect(List<int> bytes) {
    if (bytes.length >= 3 &&
        bytes[0] == 0xEF &&
        bytes[1] == 0xBB &&
        bytes[2] == 0xBF) {
      return TextEncodingKind.utf8WithBom;
    }
    if (bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE) {
      return TextEncodingKind.utf16le;
    }
    if (bytes.length >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF) {
      return TextEncodingKind.utf16be;
    }
    return TextEncodingKind.utf8;
  }

  /// Decodes [bytes]. Throws a [LocalizerFileException] on malformed input
  /// instead of silently replacing characters.
  static DecodedText decode(List<int> bytes, {String? path}) {
    final encoding = detect(bytes);
    try {
      final text = switch (encoding) {
        TextEncodingKind.utf8 => utf8.decode(bytes),
        TextEncodingKind.utf8WithBom => utf8.decode(bytes.sublist(3)),
        TextEncodingKind.utf16le => _decodeUtf16(bytes, littleEndian: true),
        TextEncodingKind.utf16be => _decodeUtf16(bytes, littleEndian: false),
      };
      return DecodedText(text, encoding);
    } on FormatException catch (e) {
      throw LocalizerFileException(
        '${path ?? 'File'} is not valid ${encoding.name} text: ${e.message}',
        path: path,
      );
    }
  }

  /// Encodes [text] using [encoding] (adding the byte-order mark if the
  /// encoding has one).
  static Uint8List encode(String text, TextEncodingKind encoding) {
    switch (encoding) {
      case TextEncodingKind.utf8:
        return Uint8List.fromList(utf8.encode(text));
      case TextEncodingKind.utf8WithBom:
        return Uint8List.fromList(
            <int>[0xEF, 0xBB, 0xBF, ...utf8.encode(text)]);
      case TextEncodingKind.utf16le:
      case TextEncodingKind.utf16be:
        final littleEndian = encoding == TextEncodingKind.utf16le;
        final units = text.codeUnits;
        final bytes = Uint8List(2 + units.length * 2);
        bytes[0] = littleEndian ? 0xFF : 0xFE;
        bytes[1] = littleEndian ? 0xFE : 0xFF;
        for (var i = 0; i < units.length; i++) {
          final unit = units[i];
          final high = (unit >> 8) & 0xFF;
          final low = unit & 0xFF;
          bytes[2 + i * 2] = littleEndian ? low : high;
          bytes[3 + i * 2] = littleEndian ? high : low;
        }
        return bytes;
    }
  }

  /// Reads and decodes the file at [path].
  static DecodedText readFile(String path) {
    final file = File(path);
    if (!file.existsSync()) {
      throw LocalizerFileException(
        'File not found: $path',
        path: path,
        isMissing: true,
      );
    }
    try {
      return decode(file.readAsBytesSync(), path: path);
    } on FileSystemException catch (e) {
      throw LocalizerFileException(
        'Unable to read $path: ${e.message}',
        path: path,
      );
    }
  }

  static String _decodeUtf16(List<int> bytes, {required bool littleEndian}) {
    final body = bytes.length - 2;
    if (body.isOdd) {
      throw const FormatException('odd number of bytes in UTF-16 data');
    }
    final units = List<int>.filled(body ~/ 2, 0);
    for (var i = 0; i < units.length; i++) {
      final first = bytes[2 + i * 2];
      final second = bytes[3 + i * 2];
      units[i] = littleEndian ? (second << 8) | first : (first << 8) | second;
    }
    return String.fromCharCodes(units);
  }
}
