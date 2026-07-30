import 'package:flutter_tts/flutter_tts.dart';

import '../models/app_settings.dart';

/// Which of the app's languages this device can actually speak.
///
/// THE REASON THIS EXISTS RATHER THAN A HARDCODED LIST. A rider who selects a
/// language the device has no voice for does not get a graceful fallback: they
/// get SILENCE from the wake alarm, on the one feature the product exists for.
/// Hindi and Marathi voices are common on Indian Android but are absent on
/// plenty of devices and on most iPhones out of the box, so the picker has to
/// ask rather than assume.
///
/// Same shape and same discipline as AudioOutputGateway: one door, failing
/// OPEN, never able to break a ride by being wrong.
class TtsLanguageGateway {
  TtsLanguageGateway({FlutterTts? tts}) : _tts = tts ?? FlutterTts();

  final FlutterTts _tts;

  /// The languages the device can speak, English always included.
  ///
  /// FAILS OPEN TO ENGLISH ALONE. If the query throws, or the plugin answers
  /// with something unreadable, the rider is offered the language the app's
  /// strings are written in and everything keeps working. An empty picker
  /// would be worse than a short one.
  Future<Set<AppLanguage>> available() async {
    try {
      final raw = await _tts.getLanguages;
      if (raw is! List) return {AppLanguage.english};

      // Match on the language SUBTAG, not the full tag. Devices report
      // 'hi-IN', 'hi_IN' and bare 'hi' depending on the engine and the OS
      // version, and an exact match on 'hi-IN' would hide a perfectly good
      // Hindi voice on half of them.
      final subtags = raw
          .map((e) => e.toString().toLowerCase().replaceAll('_', '-'))
          .map((e) => e.split('-').first)
          .toSet();

      final found = AppLanguage.values
          .where((l) => subtags.contains(l.tag.split('-').first))
          .toSet();
      return found.isEmpty ? {AppLanguage.english} : {...found, AppLanguage.english};
    } catch (_) {
      return {AppLanguage.english};
    }
  }
}
