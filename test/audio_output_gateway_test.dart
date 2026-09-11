import 'dart:async';

import 'package:audio_session/audio_session.dart';
import 'package:commute_guardian/services/audio_output_gateway.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('AN AUDIO SESSION THAT NEVER ANSWERS is unknown, not a hang', (
    tester,
  ) async {
    // `getDevices` was bounded at two seconds and `AudioSession.instance`,
    // the await in front of it, was not. It is the await that hangs under the
    // test binding, and `startRide` calls this probe AFTER the commit window
    // has said "Starting Travel Mode", so a hang there was a ride that never
    // began with nothing on screen to say so.
    final gateway = AudioOutputGateway(
      session: () => Completer<AudioSession>().future,
    );

    Object? answer = 'pending';
    unawaited(gateway.earphonesConnectedOrUnknown().then((v) => answer = v));
    await tester.pump(AudioOutputGateway.probeBudget);
    await tester.pump(const Duration(milliseconds: 100));

    expect(answer, isNull, reason: 'the platform would not say');
  });

  testWidgets('and the fail-open probe still answers true for it', (
    tester,
  ) async {
    final gateway = AudioOutputGateway(
      session: () => Completer<AudioSession>().future,
    );

    Object? answer = 'pending';
    unawaited(gateway.earphonesConnected().then((v) => answer = v));
    await tester.pump(AudioOutputGateway.probeBudget);
    await tester.pump(const Duration(milliseconds: 100));

    expect(answer, isTrue);
  });
}
