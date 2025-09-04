import 'dart:convert';
import 'package:csv/csv.dart';
import 'package:flutter/services.dart' show rootBundle;

/// Represents a single voice text row parsed from the CSV.
class VoiceTextMessage {
  final String id;
  final String name;
  final String messageText;
  final String englishText;
  final List<String> additionalColumns;

  const VoiceTextMessage({
    required this.id,
    required this.name,
    required this.messageText,
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
        csvRaw = await rootBundle.loadString(path);
        if (csvRaw.isNotEmpty) { break; }
      } catch (e) {
        lastError = e;
        try {
          final data = await rootBundle.load(path);
          // Allow malformed sequences so at least ASCII/English is preserved.
          csvRaw = const Utf8Decoder(allowMalformed: true).convert(data.buffer.asUint8List());
          if (csvRaw.isNotEmpty) { break; }
        } catch (e2) { lastError = e2; }
      }
    }
    if (csvRaw.isEmpty) {
      // ignore: avoid_print
      print('VoiceTextService: failed to load CSV from all paths. Last error: '+(lastError?.toString() ?? 'unknown'));
      throw (lastError is Exception
          ? lastError as Exception
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
      final String messageText = (row.length > 3 ? row[3] : '').toString();
      final List<String> extra = row.length > 4
          ? row.sublist(4).map((e) => (e == null) ? '' : e.toString()).toList()
          : const <String>[];

      _messagesById[id] = VoiceTextMessage(
        id: id,
        name: name,
        messageText: messageText,
        englishText: englishText,
        additionalColumns: extra,
      );
    }

    _loaded = true;
  }

  /// Returns the full row by ID, or null if missing.
  VoiceTextMessage? getById(String id) => _messagesById[id];

  /// Returns the message text by ID. If [preferEnglish] is true and the
  /// English column is non-empty, it will be returned instead.
  String? getTextById(String id, {bool preferEnglish = false}) {
    final msg = _messagesById[id];
    if (msg == null) return null;
    if (preferEnglish && msg.englishText.trim().isNotEmpty) return msg.englishText;
    return msg.messageText;
  }

  /// Exposes a read-only view of the mapping.
  Map<String, VoiceTextMessage> get messagesById => Map.unmodifiable(_messagesById);
}


