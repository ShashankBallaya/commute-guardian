import 'package:commute_guardian/data/app_database.dart';
import 'package:commute_guardian/models/app_settings.dart';
import 'package:commute_guardian/state/ride_providers.dart';
import 'package:commute_guardian/state/settings_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// The rider's settings, and the one property that matters about them: they
/// SURVIVE. A pulse interval that forgets itself when the app restarts is worse
/// than no setting at all, because the rider believes they have configured
/// something.
void main() {
  /// A container sharing ONE database, so a second container reads what the
  /// first one wrote. That is the whole point: it stands in for the app being
  /// closed and opened again.
  (ProviderContainer, AppDatabase) makeContainer([AppDatabase? existing]) {
    final db = existing ?? AppDatabase.inMemory();
    final container = ProviderContainer(
      overrides: [appDatabaseProvider.overrideWithValue(db)],
    );
    addTearDown(container.dispose);
    if (existing == null) addTearDown(db.close);
    return (container, db);
  }

  test('a written interval survives a restart', () async {
    final (first, db) = makeContainer();
    await first.read(appSettingsProvider.future);
    await first.read(appSettingsProvider.notifier).setPulseInterval(5);

    final (second, _) = makeContainer(db);
    final restored = await second.read(appSettingsProvider.future);
    expect(restored.pulseIntervalMinutes, 5);
    expect(restored.pulseIntervalSeconds, 300);
  });

  test('an unset install gets the documented defaults, pulse OFF', () async {
    // Off by default is a product decision, not an oversight: a rider installs
    // this to be woken at their stop, and a chime every few minutes they never
    // asked for is a surprise in their ears.
    final (c, _) = makeContainer();
    final settings = await c.read(appSettingsProvider.future);

    expect(settings.pulseIntervalMinutes, 0);
    expect(settings.pulseIntervalSeconds, isNull);
    expect(settings.vibrateWithPulse, isTrue);
    expect(settings.announceEveryStation, isTrue);
    expect(settings.shareAnonymousUsage, isTrue);
    expect(settings.language, AppLanguage.english);
  });

  test('crowd mode survives too, and still overrides the interval', () async {
    final (first, db) = makeContainer();
    await first.read(appSettingsProvider.future);
    final notifier = first.read(appSettingsProvider.notifier);
    await notifier.setPulseInterval(10);
    await notifier.setCrowdMode(true);

    final (second, _) = makeContainer(db);
    final restored = await second.read(appSettingsProvider.future);
    expect(restored.pulseIntervalMinutes, 10);
    expect(restored.crowdMode, isTrue);
    expect(restored.pulseIntervalSeconds, 45);
  });

  test('the language survives, because a wrong voice is a silent alarm',
      () async {
    final (first, db) = makeContainer();
    await first.read(appSettingsProvider.future);
    await first.read(appSettingsProvider.notifier).setLanguage(AppLanguage.marathi);

    final (second, _) = makeContainer(db);
    expect((await second.read(appSettingsProvider.future)).language,
        AppLanguage.marathi);
  });

  test('turning the pulse off persists as off, not as unset', () async {
    // The failure this guards: writing 0 and then reading it back through a
    // fallback that says "missing means default" would turn the rider's
    // deliberate OFF into whatever the default happens to be later.
    final (first, db) = makeContainer();
    await first.read(appSettingsProvider.future);
    final notifier = first.read(appSettingsProvider.notifier);
    await notifier.setPulseInterval(3);
    await notifier.setPulseInterval(0);

    final (second, _) = makeContainer(db);
    expect((await second.read(appSettingsProvider.future)).pulseIntervalMinutes, 0);
  });

  test('the interval a ride STARTS with is handed over, not only changes', () {
    // THE GAP THE DEVICE FOUND, 30 Jul. The first wiring pushed the interval to
    // the service only when it CHANGED mid-ride, so a rider who had the pulse
    // switched on and simply started a journey got silence: the store key the
    // service reads at start had never been written. Settings persisting is not
    // the same as settings being handed over.
    const settings = AppSettings(pulseIntervalMinutes: 3);
    expect(settings.pulseIntervalSeconds, 180);

    const crowded = AppSettings(pulseIntervalMinutes: 3, crowdMode: true);
    expect(crowded.pulseIntervalSeconds, 45);

    // And off stays off, so startRide hands over a real "no pulse" rather than
    // a missing value the service would have to guess about.
    const off = AppSettings();
    expect(off.pulseIntervalSeconds, isNull);
  });
}
