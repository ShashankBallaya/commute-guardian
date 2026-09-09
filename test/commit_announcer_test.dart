import 'package:commute_guardian/models/app_settings.dart';
import 'package:commute_guardian/services/commit_announcer.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_tts/flutter_tts.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('the budget', () {
    testWidgets('a slow engine that finishes is still heard out', (
      tester,
    ) async {
      // FIVE SECONDS, and the number is not arbitrary. The 9 Sep 2026 ride
      // heard the Sarvam welcome speak over a commit line that was still
      // going: a cold Android engine (500 to 900 ms, 16 Aug bench) plus a
      // route line with two long station names in it crossed the old 4 s
      // budget, the timeout returned, and the ride started underneath a live
      // utterance. A budget shorter than a real cold utterance is the bug.
      final engine = _SlowTts(const Duration(seconds: 5));
      final announcer = CommitAnnouncer(tts: engine);

      final spoken = announcer.speak(
        'Starting Travel Mode, from Kalyan to Dadar Western.',
        language: AppLanguage.english,
      );
      await tester.pump(const Duration(seconds: 5));

      expect(await spoken, isTrue);
    });
  });

  group('the warm-up', () {
    testWidgets('pays the cold start without the rider hearing it', (
      tester,
    ) async {
      // WHY A WARM-UP EXISTS AT ALL. The engine that speaks the commit window
      // lives in the UI isolate and had no pre-warm, while the ride announcer
      // in the service isolate has had one since Phase 1
      // (`_preWarmTts`). So the FIRST window of every app launch paid a cold
      // start that no later one paid, which is exactly the asymmetry the 9 Sep
      // 2026 3T ride heard.
      final engine = _RecordingTts();
      final announcer = CommitAnnouncer(tts: engine);

      await announcer.warmUp();

      // IT SPOKE, because an engine only loads when it is asked to speak.
      expect(engine.spoken, isNotEmpty);
      // AND THE RIDER HEARD NOTHING. Every utterance happened while the
      // volume was zero.
      expect(engine.volumeWhileSpeaking, everyElement(0.0));
      // AND THE VOLUME CAME BACK, or the window it was meant to help would be
      // the silent one.
      expect(engine.volume, 1.0);
    });

    testWidgets('a dead engine is not an error', (tester) async {
      // IT CAN NEVER COST A RIDE. This runs on Screen 1, nowhere near a
      // decision, so every failure it can have is a silent one.
      final announcer = CommitAnnouncer(tts: _ThrowingTts());

      await expectLater(announcer.warmUp(), completes);
    });
  });
}

/// Records what was said and how loud the engine was while it said it.
class _RecordingTts extends FlutterTts {
  final List<String> spoken = <String>[];
  final List<double> volumeWhileSpeaking = <double>[];
  double volume = 1;

  @override
  Future<dynamic> setLanguage(String language) async => 1;

  @override
  Future<dynamic> setSpeechRate(double rate) async => 1;

  @override
  Future<dynamic> awaitSpeakCompletion(bool value) async => 1;

  @override
  Future<dynamic> setVolume(double v) async {
    volume = v;
    return 1;
  }

  @override
  Future<dynamic> speak(String text, {bool focus = false}) async {
    spoken.add(text);
    volumeWhileSpeaking.add(volume);
    return 1;
  }
}

/// An engine that has nothing behind it, which is a real phone with no voice
/// data for the language installed.
class _ThrowingTts extends FlutterTts {
  @override
  Future<dynamic> setVolume(double volume) async => throw StateError('no engine');

  @override
  Future<dynamic> speak(String text, {bool focus = false}) async =>
      throw StateError('no engine');
}

/// An engine that answers, but takes its time about it.
class _SlowTts extends FlutterTts {
  _SlowTts(this.delay);

  final Duration delay;

  @override
  Future<dynamic> setLanguage(String language) async => 1;

  @override
  Future<dynamic> setSpeechRate(double rate) async => 1;

  @override
  Future<dynamic> awaitSpeakCompletion(bool value) async => 1;

  @override
  Future<dynamic> speak(String text, {bool focus = false}) =>
      Future<dynamic>.delayed(delay, () => 1);
}
