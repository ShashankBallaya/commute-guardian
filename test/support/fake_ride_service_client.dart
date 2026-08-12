import 'dart:async';

import 'package:commute_guardian/models/app_settings.dart';
import 'package:commute_guardian/services/ride_service_client.dart';

/// A [RideServiceClient] with the isolate boundary removed.
///
/// The real client's every method reaches a plugin channel that does not exist
/// under the widget-test binding, so this stands in: commands are RECORDED
/// rather than sent, events are PUSHED by the test rather than received, and
/// the shared store is a couple of fields.
///
/// IMPLEMENTS rather than extends, deliberately. It overrides every public
/// member and inherits nothing, so subclassing bought only a second, never
/// closed StreamController from the real client's constructor. Implementing
/// also means the analyzer fails this file the moment the client grows a
/// member, instead of silently inheriting a plugin call into the test suite.
///
/// The important one is [running] plus [originId] / [destinationId]: those are
/// what a recreated process reads back, so setting them here is how a test
/// says "the service was already running before this screen existed".
class FakeRideServiceClient implements RideServiceClient {
  FakeRideServiceClient({
    this.running = false,
    this.originId,
    this.destinationId,
    this.destinationReached = false,
    this.startedAt,
    this.startBatteryPct,
    this.wakeLadderLive = false,
    this.windDownLive = false,
    this.alightStationId,
  });

  bool running;
  String? originId;
  String? destinationId;
  bool destinationReached;

  /// The history row's seed, which lives in the real store so a ride swiped out
  /// of recents keeps its record.
  DateTime? startedAt;
  int? startBatteryPct;

  /// Alerts the service says are live. Persisted since 30 Jul, so a screen born
  /// mid-alarm can find out it has an alarm to answer.
  bool wakeLadderLive;
  bool windDownLive;

  /// Where the rider gets off, null for the destination they picked. Only an
  /// overshoot moves it.
  String? alightStationId;

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

  /// What the volume probe answers. NULL BY DEFAULT, matching a platform that
  /// will not say, so no existing test starts seeing a volume warning it never
  /// asked about. A test that wants the warning sets a number.
  double? alarmVolumeValue;

  @override
  Future<double?> alarmVolume() async => alarmVolumeValue;

  /// Native vibrations asked for. Recorded rather than sent, like every other
  /// command here.
  int vibrateCount = 0;

  @override
  Future<void> sendNativeVibrate() async => vibrateCount++;

  @override
  Future<PersistedRide> readPersistedRide() async => PersistedRide(
    originId: originId,
    destinationId: destinationId,
    destinationReached: destinationReached,
    startedAt: startedAt,
    startBatteryPct: startBatteryPct,
    wakeLadderLive: wakeLadderLive,
    windDownLive: windDownLive,
    alightStationId: alightStationId,
  );

  @override
  Future<void> clearRideRecordSeed() async {
    commands.add('clearRideRecordSeed');
    startedAt = null;
    startBatteryPct = null;
  }

  /// What the last startRide was told about the analytics opt-out.
  bool? shareAnonymousUsagePassed;

  /// And what it was told to speak in. Same reason as above: the language is
  /// read in the UI isolate and has to survive the crossing.
  AppLanguage? languagePassed;

  @override
  Future<bool> startRide({
    required String originStationId,
    required String destinationStationId,
    required String notificationText,
    required bool sarvamGreeting,
    required bool sarvamClips,
    required DateTime startedAt,
    int? startBatteryPct,
    int? pulseIntervalSeconds,
    bool pulseVibrate = true,
    bool shareAnonymousUsage = false,
    AppLanguage language = AppLanguage.english,
  }) async {
    commands.add('startRide:$originStationId->$destinationStationId');
    languagePassed = language;
    // Recorded so a test can prove the rider's opt-out actually reaches the
    // service isolate, rather than being read in the UI and dropped at the
    // boundary the way the pulse interval once was.
    shareAnonymousUsagePassed = shareAnonymousUsage;
    if (pulseIntervalSeconds != null) {
      commands.add('startPulse:$pulseIntervalSeconds');
    }
    running = true;
    originId = originStationId;
    destinationId = destinationStationId;
    this.startedAt = startedAt;
    this.startBatteryPct = startBatteryPct;
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
  Future<void> setPulseInterval({required int? seconds, bool? vibrate}) async =>
      commands.add('setPulseInterval:${seconds ?? 'off'}');

  @override
  void testPulse() => commands.add('testPulse');

  @override
  void testPulseCollision({int afterMs = 150}) =>
      commands.add('testPulseCollision:$afterMs');

  @override
  void testWindDown() => commands.add('testWindDown');

  /// Screen 4's wake toggle, recorded so a test can assert the RIDE was told
  /// and not merely the screen.
  final List<bool> wakeEnabled = [];

  @override
  void setWakeEnabled(bool enabled) => wakeEnabled.add(enabled);
}
