import 'dart:io';

import 'package:flutter_tts/flutter_tts.dart';
import 'package:web_tasks_bot/services/voice_text_service.dart';

/// A small, reusable Text-to-Speech service.
///
/// On Android, this uses the built-in system TTS engine. When available,
/// it will prefer the Google Speech Services engine for higher quality.
class TtsService {
  TtsService._internal();

  static final TtsService instance = TtsService._internal();

  final FlutterTts _tts = FlutterTts();
  bool _initialized = false;
  String _languageName = 'En'; // 'En' or 'He'

  /// Initialize TTS settings once. Safe to call multiple times.
  Future<void> _initializeIfNeeded() async {
    if (_initialized) return;

    // Prefer Google Speech Services if present on Android.
    if (Platform.isAndroid) {
      try {
        final engines = await _tts.getEngines as List<dynamic>?;
        final engineIds = engines?.map((e) => e.toString()).toList() ?? <String>[];
        if (engineIds.contains('com.google.android.tts')) {
          await _tts.setEngine('com.google.android.tts');
        }
      } catch (_) {}
    }

    try {
      // Apply current language preference on init
      await _applyCurrentTtsLanguage();
    } catch (_) {}

    try {
      await _tts.setSpeechRate(0.5);
    } catch (_) {}

    try {
      await _tts.setPitch(1.0);
    } catch (_) {}

    try {
      await _tts.awaitSpeakCompletion(true);
    } catch (_) {}

    _initialized = true;
  }

  Future<void> _applyCurrentTtsLanguage() async {
    final isEnglish = _languageName.trim().toLowerCase().startsWith('en');
    final locale = isEnglish ? 'en-US' : 'he-IL';
    try { await _tts.setLanguage(locale); } catch (_) {}
  }

  /// Set current language by menu selection (e.g., 'En' or 'He').
  Future<void> setLanguageByMenu(String languageName) async {
    _languageName = languageName;
    if (_initialized) {
      await _applyCurrentTtsLanguage();
    }
  }

  /// Speak the provided [text]. If [interrupt] is true (default), any ongoing
  /// speech is stopped before speaking the new text.
  Future<void> speak(String text, {bool interrupt = true}) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    await _initializeIfNeeded();
    await _applyCurrentTtsLanguage();
    if (interrupt) {
      await stop();
    }
    try {
      await _tts.speak(trimmed);
    } catch (_) {}
  }

  Future<void> stop() async {
    try {
      await _tts.stop();
    } catch (_) {}
  }

  /// Speak a message from the CSV by its [id], using [languageName] ('En'/'He').
  Future<void> speakMessageById(String id, {bool interrupt = true, String languageName = 'En'}) async {
    try {
      if (!VoiceTextService.instance.isLoaded) {
        try {
          await VoiceTextService.instance.loadFromAssets();
        } catch (e) {
          // ignore: avoid_print
          print('TtsService: VoiceTextService load failed: '+e.toString());
          rethrow;
        }
      }
      await setLanguageByMenu(languageName);
      final text = VoiceTextService.instance.getTextById(id, languageName: languageName);
      if (text == null || text.trim().isEmpty) return;
      await speak(text, interrupt: interrupt);
    } catch (_) {}
  }
}


