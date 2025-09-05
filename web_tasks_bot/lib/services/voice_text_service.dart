import 'dart:convert';
import 'dart:typed_data';
import 'package:csv/csv.dart';
import 'package:flutter/services.dart' show rootBundle;

/// Represents a single voice text row parsed from the CSV.
class VoiceTextMessage {
  final String id;
  final String name;
  final String hebrewText;
  final String englishText;
  final List<String> additionalColumns;

  const VoiceTextMessage({
    required this.id,
    required this.name,
    required this.hebrewText,
    required this.englishText,
    required this.additionalColumns,
  });
}

/// Loads and serves voice text messages from assets/voice_text/voice_text.csv
class VoiceTextService {
  VoiceTextService._internal();
  static final VoiceTextService instance = VoiceTextService._internal();

  final Map<String, VoiceTextMessage> _messagesById = <String, VoiceTextMessage>{};
  bool _loaded = false;

  bool get isLoaded => _loaded;

  /// Loads the CSV once from assets. Safe to call multiple times.
  Future<void> loadFromAssets({String assetPath = 'assets/voice_text/voice_text.csv'}) async {
    if (_loaded && _messagesById.isNotEmpty) return;
    String csvRaw = '';
    final candidates = <String>[
      assetPath,
      'packages/web_tasks_bot/assets/voice_text/voice_text.csv',
    ];
    Object? lastError;
    for (final path in candidates) {
      try {
        // Prefer decoding bytes ourselves to properly support non-UTF8 encodings
        // such as Windows-1255 for Hebrew.
        final data = await rootBundle.load(path);
        csvRaw = _decodeCsvBytes(data.buffer.asUint8List());
        if (csvRaw.isNotEmpty) { break; }
      } catch (e) {
        lastError = e;
        // Keep trying other candidate paths
      }
    }
    if (csvRaw.isEmpty) {
      // ignore: avoid_print
      print('VoiceTextService: failed to load CSV from all paths. Last error: '+(lastError?.toString() ?? 'unknown'));
      throw (lastError is Exception
          ? lastError
          : Exception('VoiceTextService: CSV asset missing: '+(lastError?.toString() ?? 'unknown')));
    }
    final rows = const CsvToListConverter(eol: '\n').convert(csvRaw);
    if (rows.isEmpty) {
      _loaded = true;
      return;
    }

    int startIndex = 0;
    // Skip header row if it looks like a header (first cell equals 'ID' case-insensitively)
    final firstRow = rows.first;
    if (firstRow.isNotEmpty && firstRow[0].toString().trim().toLowerCase() == 'id') {
      startIndex = 1;
    }

    for (int i = startIndex; i < rows.length; i++) {
      final row = rows[i];
      if (row.isEmpty) continue;

      final String id = (row.length > 0 ? row[0] : '').toString().trim();
      if (id.isEmpty || id.toLowerCase() == 'hear') {
        // Ignore empty or special marker lines (e.g., 'hear' line if present)
        continue;
      }
      final String name = (row.length > 1 ? row[1] : '').toString();
      // Header: ID, Message name, Message text, English, Message text, Hebrew, comments
      final String englishText = (row.length > 2 ? row[2] : '').toString();
      final String hebrewText = (row.length > 3 ? row[3] : '').toString();
      final List<String> extra = row.length > 4
          ? row.sublist(4).map((e) => (e == null) ? '' : e.toString()).toList()
          : const <String>[];

      _messagesById[id] = VoiceTextMessage(
        id: id,
        name: name,
        hebrewText: hebrewText,
        englishText: englishText,
        additionalColumns: extra,
      );
    }

    _loaded = true;
  }

  /// Returns the full row by ID, or null if missing.
  VoiceTextMessage? getById(String id) => _messagesById[id];

  /// Returns the message text by ID according to [languageName].
  ///
  /// Supported values: 'En' (English), 'He' (Hebrew). Defaults to Hebrew
  /// when not explicitly English.
  String? getTextById(String id, {String languageName = 'En'}) {
    final msg = _messagesById[id];
    if (msg == null) return null;
    final lang = languageName.trim();
    final isEnglish = lang.toLowerCase().startsWith('en');
    if (isEnglish) {
      final english = msg.englishText.trim();
      if (english.isNotEmpty) return english;
      return msg.hebrewText.trim(); // fallback
    }
    final hebrew = msg.hebrewText.trim();
    if (hebrew.isNotEmpty) return hebrew;
    return msg.englishText; // fallback
  }

  /// Exposes a read-only view of the mapping.
  Map<String, VoiceTextMessage> get messagesById => Map.unmodifiable(_messagesById);
}

/// Decodes CSV bytes, trying strict UTF-8 first, then falling back to a
/// best-effort Windows-1255 (Hebrew) mapping if UTF-8 fails.
String _decodeCsvBytes(Uint8List bytes) {
  // Try strict UTF-8 first
  try {
    return utf8.decode(bytes, allowMalformed: false);
  } catch (_) {
    // Fallback to Windows-1255 mapping
  }

  // As an intermediate step, decode as ISO-8859-1 to get 1:1 code units
  // for the original bytes, then map Windows-1255 Hebrew range.
  final intermediate = latin1.decode(bytes, allowInvalid: true);
  final buffer = StringBuffer();
  for (final int unit in intermediate.codeUnits) {
    buffer.writeCharCode(_mapWindows1255UnitToUnicode(unit));
  }
  return buffer.toString();
}

/// Maps a single code unit (0..255) from Windows-1255 to Unicode.
/// For ASCII (0x00..0x7F), this returns the same value.
/// For most non-Hebrew values we keep Latin-1 mapping; for Hebrew letters
/// 0xE0..0xFA we map to U+05D0..U+05EA including finals.
int _mapWindows1255UnitToUnicode(int unit) {
  if (unit <= 0x7F) return unit; // ASCII

  // Hebrew letters and finals
  switch (unit) {
    // Finals
    case 0xEA: return 0x05DA; // ך
    case 0xED: return 0x05DD; // ם
    case 0xEF: return 0x05DF; // ן
    case 0xF3: return 0x05E3; // ף
    case 0xF5: return 0x05E5; // ץ

    // Regular letters
    case 0xE0: return 0x05D0; // א
    case 0xE1: return 0x05D1; // ב
    case 0xE2: return 0x05D2; // ג
    case 0xE3: return 0x05D3; // ד
    case 0xE4: return 0x05D4; // ה
    case 0xE5: return 0x05D5; // ו
    case 0xE6: return 0x05D6; // ז
    case 0xE7: return 0x05D7; // ח
    case 0xE8: return 0x05D8; // ט
    case 0xE9: return 0x05D9; // י
    case 0xEB: return 0x05DB; // כ
    case 0xEC: return 0x05DC; // ל
    case 0xEE: return 0x05DE; // מ
    case 0xF0: return 0x05E0; // נ
    case 0xF1: return 0x05E1; // ס
    case 0xF2: return 0x05E2; // ע
    case 0xF4: return 0x05E4; // פ
    case 0xF6: return 0x05E6; // צ
    case 0xF7: return 0x05E7; // ק
    case 0xF8: return 0x05E8; // ר
    case 0xF9: return 0x05E9; // ש
    case 0xFA: return 0x05EA; // ת
  }

  // Common punctuation in Windows-125x kept via Latin-1 mapping
  // (This preserves characters like NBSP, quotes, dashes, etc., reasonably.)
  return unit;
}

