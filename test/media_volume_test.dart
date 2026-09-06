import 'package:commute_guardian/services/ride_service_client.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// THE INSTRUMENT THE 5 SEP 2026 RIDE DID NOT HAVE.
///
/// A tester heard no station announcements and no spoken wake, on a phone whose
/// log recorded "Alarm volume at start: 100%". Both facts were true at once,
/// because the ladder tone rides the alarm stream and everything the app SAYS
/// rides the media stream. Nothing in six logs across three phones could
/// separate a muted media slider from a broken app, so the question was settled
/// by asking the rider what he remembered.
///
/// A DIAGNOSTIC, NEVER A WARNING. This number cannot reach the alarm and must
/// never gate a claim about whether the alarm can be heard. The preflight
/// already owns warning a rider, and a second opinion arriving mid-ride is a
/// warning nobody can act on with the phone in a pocket.
void main() {
  const channel = MethodChannel('commute_guardian/media_ack');
  final client = RideServiceClient();

  void answer(Object? Function() reply) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method != 'getMediaVolume') return null;
          return reply();
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
  }

  setUp(TestWidgetsFlutterBinding.ensureInitialized);

  test('a real slider reading comes back as it was measured', () async {
    answer(() => 0.42);
    expect(await client.mediaVolume(), closeTo(0.42, 1e-9));
  });

  test('a muted phone reads zero, which is the whole point of asking', () async {
    // Not null, not absent: ZERO. This is the reading that would have answered
    // "I heard nothing" in one line instead of a conversation.
    answer(() => 0.0);
    expect(await client.mediaVolume(), 0.0);
  });

  test('a platform that will not say answers null, never a guess', () async {
    answer(() => null);
    expect(await client.mediaVolume(), isNull);
  });

  test('a negative reading is refused rather than clamped up to zero', () async {
    // Android hands back -1 from its own failure path, and 0.0 would be a
    // MEASUREMENT of a muted phone. Those must never be the same answer, or the
    // log would report a silent phone every time the read failed.
    answer(() => -1.0);
    expect(await client.mediaVolume(), isNull);
  });

  test(
    'a reading past full scale is clamped rather than reported raw',
    () async {
      answer(() => 1.4);
      expect(await client.mediaVolume(), 1.0);
    },
  );

  test('a channel nobody implements answers null instead of throwing', () async {
    // iOS today, and any desktop host. The read sits on the ride-start path, so
    // an exception here would be an exception in front of a ride starting.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    expect(await client.mediaVolume(), isNull);
  });
}
