import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// EVERY COMMAND THE UI SENDS MUST BE HANDLED WHERE IT ACTUALLY ARRIVES.
///
/// THE 16 SEP 2026 BUG THIS EXISTS FOR. `RideServiceClient.setWakeEnabled`
/// sends `wake_enabled:<bool>` through `sendDataToTask`, which the plugin
/// delivers to `onReceiveData`. The case that read it was written in
/// `onNotificationButtonPressed`, which only ever receives NOTIFICATION BUTTON
/// IDS. So the message was pattern-matched in a handler it could never reach,
/// and the wake toggle on Screen 4 did nothing for the life of the control: a
/// rider could switch their alarm to "Wake-up off" and the ladder stayed armed.
///
/// NOTHING CAUGHT IT, and that is the interesting part. The widget tests pass a
/// `FakeRideServiceClient` and assert the SCREEN calls `setWakeEnabled`, which
/// it always did. The service side was never joined to the UI side by anything.
/// Two correct halves, wired to each other through a string, with no test on
/// the wire.
///
/// READ FROM THE SOURCE because the seam is a platform channel: the plugin is
/// what routes a payload to a handler, and it does not exist under the test
/// binding. This checks the property that the channel makes true.
void main() {
  late String client;
  late String handler;
  late String onReceiveData;
  late String onNotificationButtonPressed;

  /// The body of a method, from its signature to the line that closes it at
  /// the method's own indent.
  String bodyOf(String source, String signature) {
    final start = source.indexOf(signature);
    expect(start, greaterThan(-1), reason: '$signature is gone or renamed');
    final end = source.indexOf('\n  }', start);
    expect(end, greaterThan(start));
    return source.substring(start, end);
  }

  setUpAll(() {
    client = File(
      'lib/services/ride_service_client.dart',
    ).readAsStringSync();
    handler = File(
      'lib/foreground/geofence_task_handler.dart',
    ).readAsStringSync();
    onReceiveData = bodyOf(handler, 'void onReceiveData(Object data) {');
    onNotificationButtonPressed = bodyOf(
      handler,
      'void onNotificationButtonPressed(String id) {',
    );
  });

  test('THE WAKE TOGGLE IS READ WHERE sendDataToTask DELIVERS IT', () {
    // The bug in one property. Both halves existed and neither was wrong on
    // its own; they were simply not connected.
    expect(
      onReceiveData,
      contains('wakeEnabledPrefix'),
      reason: 'the wake toggle is sent with sendDataToTask, so it arrives in '
          'onReceiveData. A case anywhere else is never reached, and the '
          'rider cannot switch off their own alarm.',
    );
    expect(
      onNotificationButtonPressed,
      isNot(contains('wakeEnabledPrefix')),
      reason: 'onNotificationButtonPressed receives notification button IDs, '
          'never a sendDataToTask payload. This is where the case used to be.',
    );
  });

  test('EVERY sendDataToTask PAYLOAD HAS A CASE IN onReceiveData', () {
    // THE GENERAL PROPERTY, not just the one bug. Every command the UI isolate
    // sends crosses the same wire, so every one of them can be lost the same
    // way. This is the guard that catches the NEXT one.
    //
    // Two shapes are sent: a bare literal ('test_tts') and a prefix constant
    // interpolated with a value ('$wakeEnabledPrefix$enabled').
    final literals = RegExp(r"sendDataToTask\('([a-z_]+)'\)")
        .allMatches(client)
        .map((m) => m.group(1)!)
        .toSet();
    final prefixes = RegExp(r"sendDataToTask\('\$(\w+)")
        .allMatches(client)
        .map((m) => m.group(1)!)
        .toSet();

    expect(
      literals,
      isNotEmpty,
      reason: 'the payload shapes changed, so this guard is reading nothing',
    );
    expect(prefixes, isNotEmpty, reason: 'the same, for prefixed commands');

    for (final literal in literals) {
      expect(
        onReceiveData,
        contains("'$literal'"),
        reason: "the UI sends '$literal' and onReceiveData never reads it",
      );
    }
    for (final prefix in prefixes) {
      expect(
        onReceiveData,
        contains(prefix),
        reason: 'the UI sends $prefix and onReceiveData never reads it',
      );
    }
  });

  test('the ack arrives on BOTH wires, and says which one it came from', () {
    // Not a bug, a property worth pinning: the "I'm awake" button exists on the
    // screen AND on the notification, so its id is handled in both places on
    // purpose. The ride log tells them apart, which is how the 14 Sep ride
    // could report that acks worked from both surfaces.
    expect(onReceiveData, contains('wakeAckButtonId'));
    expect(onNotificationButtonPressed, contains('wakeAckButtonId'));
    expect(onReceiveData, contains("source: 'screen button'"));
    expect(
      onNotificationButtonPressed,
      contains("source: 'notification button'"),
    );
  });
}
