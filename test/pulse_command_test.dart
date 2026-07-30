import 'package:commute_guardian/foreground/geofence_task_handler.dart';
import 'package:flutter_test/flutter_test.dart';

/// The UI-to-service wire format for the Pocket Pulse interval.
///
/// Pure, and tested for the same reason [parseServiceData] is: this is a STRING
/// crossing an isolate boundary with a plugin either side, so a typo in the
/// prefix or a mishandled payload is invisible to every other test and shows up
/// only on a device, mid-ride.
void main() {
  test('an interval crosses as seconds', () {
    expect(parsePulseCommand('${pulseSetPrefix}180')?.intervalS, 180);
  });

  test('off crosses as off, and is a command rather than an absence', () {
    // The distinction matters: null intervalS means "the rider turned it off",
    // while a null COMMAND means "this message was not about the pulse". A
    // parser that collapsed the two would let a garbled message silence the
    // pulse for the rest of the ride.
    final command = parsePulseCommand('${pulseSetPrefix}off');
    expect(command, isNotNull);
    expect(command!.intervalS, isNull);
  });

  test('A GARBLED PAYLOAD IS IGNORED, never read as off', () {
    expect(parsePulseCommand('${pulseSetPrefix}banana'), isNull);
    expect(parsePulseCommand(pulseSetPrefix), isNull);
  });

  test('other messages are not pulse commands', () {
    expect(parsePulseCommand('test_tts'), isNull);
    expect(parsePulseCommand(wakeAckButtonId), isNull);
    expect(parsePulseCommand(42), isNull);
  });
}
