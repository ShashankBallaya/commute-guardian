import 'dart:async';

import 'package:commute_guardian/services/ride_service_client.dart';

/// A [RideServiceClient] with the isolate boundary removed.
///
/// The real client's every method reaches a plugin channel that does not exist
/// under the widget-test binding, so this stands in: commands are RECORDED
/// rather than sent, events are PUSHED by the test rather than received, and
/// the shared store is a couple of fields.
///
/// The important one is [running] plus [originId] / [destinationId]: those are
/// what a recreated process reads back, so setting them here is how a test
/// says "the service was already running before this screen existed".
class FakeRideServiceClient extends RideServiceClient {
  FakeRideServiceClient({
    this.running = false,
    this.originId,
    this.destinationId,
    this.destinationReached = false,
  });

  bool running;
  String? originId;
  String? destinationId;
  bool destinationReached;

  /// Every command the screen sent, in order, for assertions.
  final List<String> commands = [];

  final _fakeEvents = StreamController<ServiceEvent>.broadcast();

  @override
  Stream<ServiceEvent> get events => _fakeEvents.stream;

  /// Pushes an event as if the service isolate had sent it.
  void emit(ServiceEvent event) => _fakeEvents.add(event);

  @override
  void start() {}

  @override
  void dispose() => unawaited(_fakeEvents.close());

  @override
  Future<bool> isRunning() async => running;

  @override
  Future<PersistedRide> readPersistedRide() async => PersistedRide(
        originId: originId,
        destinationId: destinationId,
        destinationReached: destinationReached,
      );

  @override
  Future<bool> startRide({
    required String originStationId,
    required String destinationStationId,
    required String notificationText,
    required bool sarvamGreeting,
    required bool sarvamClips,
  }) async {
    commands.add('startRide:$originStationId->$destinationStationId');
    running = true;
    originId = originStationId;
    destinationId = destinationStationId;
    return true;
  }

  @override
  Future<void> stopRide() async {
    commands.add('stopRide');
    running = false;
  }

  @override
  Future<void> setMediaSession(bool active) async =>
      commands.add('setMediaSession:$active');

  @override
  Future<void> sendNativeTone(String command, double volume) async =>
      commands.add('tone:$command:$volume');

  @override
  Future<void> requestBatteryOptimizationExemption() async {}

  @override
  void ackWakeFromButton() => commands.add('ackWake');

  @override
  void windDownEndNow() => commands.add('windDownEndNow');

  @override
  void windDownExtend() => commands.add('windDownExtend');

  @override
  void testTts() => commands.add('testTts');

  @override
  void testWakeAlert() => commands.add('testWakeAlert');

  @override
  void testWindDown() => commands.add('testWindDown');
}
