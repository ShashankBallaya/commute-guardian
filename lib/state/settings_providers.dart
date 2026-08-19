import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/app_database.dart';
import '../models/app_settings.dart';
import '../services/analytics.dart';
import '../services/tts_language_gateway.dart';
import 'ride_providers.dart';

/// Settings keys. Strings rather than an enum because AppFlags is a string
/// table and these end up in a database a future version has to read back.
const pulseIntervalKey = 'pulse_interval_minutes';
const crowdModeKey = 'pulse_crowd_mode';
const vibrateWithPulseKey = 'pulse_vibrate';
const announceEveryStationKey = 'announce_every_station';
const shareAnonymousUsageKey = 'share_anonymous_usage';
const languageKey = 'language_tag';

/// The rider's choices, read once at launch and written through on every change.
///
/// NOT autoDispose. Settings are read by the ride start path, not only by the
/// Settings screen, so this outlives the screen that edits it.
class AppSettingsNotifier extends AsyncNotifier<AppSettings> {
  @override
  Future<AppSettings> build() => _read();

  AppDatabase get _db => ref.read(appDatabaseProvider);

  Future<AppSettings> _read() async {
    // Defaults live in AppSettings' constructor, so a missing key and a fresh
    // install give the same answer, and there is exactly one place that says
    // what "unset" means.
    const fallback = AppSettings();
    return AppSettings(
      pulseIntervalMinutes:
          int.tryParse(await _db.flag(pulseIntervalKey) ?? '') ??
          fallback.pulseIntervalMinutes,
      crowdMode: await _boolFlag(crowdModeKey, fallback.crowdMode),
      vibrateWithPulse: await _boolFlag(
        vibrateWithPulseKey,
        fallback.vibrateWithPulse,
      ),
      announceEveryStation: await _boolFlag(
        announceEveryStationKey,
        fallback.announceEveryStation,
      ),
      shareAnonymousUsage: await _boolFlag(
        shareAnonymousUsageKey,
        fallback.shareAnonymousUsage,
      ),
      // COERCED, NOT JUST HIDDEN. A phone that stored hindi before the
      // picker was locked would otherwise keep riding in a language the
      // rider can no longer see, let alone change back.
      language: _selectableOnly(AppLanguage.fromTag(await _db.flag(languageKey))),
    );
  }

  Future<bool> _boolFlag(String key, bool fallback) async =>
      switch (await _db.flag(key)) {
        'true' => true,
        'false' => false,
        _ => fallback,
      };

  /// Writes one key and updates the projection.
  ///
  /// The state moves FIRST so the switch under the rider's finger answers
  /// immediately, then the write lands. A settings toggle that waits on a disk
  /// write to redraw feels broken, and this database is local and small enough
  /// that the write is not in doubt.
  Future<void> _set(String key, String value, AppSettings next) async {
    state = AsyncData(next);
    await _db.setFlag(key, value);
  }

  Future<void> setPulseInterval(int minutes) => _set(
    pulseIntervalKey,
    '$minutes',
    _now.copyWith(pulseIntervalMinutes: minutes),
  );

  Future<void> setCrowdMode(bool on) =>
      _set(crowdModeKey, '$on', _now.copyWith(crowdMode: on));

  Future<void> setVibrateWithPulse(bool on) =>
      _set(vibrateWithPulseKey, '$on', _now.copyWith(vibrateWithPulse: on));

  Future<void> setAnnounceEveryStation(bool on) => _set(
    announceEveryStationKey,
    '$on',
    _now.copyWith(announceEveryStation: on),
  );

  Future<void> setShareAnonymousUsage(bool on) => _set(
    shareAnonymousUsageKey,
    '$on',
    _now.copyWith(shareAnonymousUsage: on),
  );

  Future<void> setLanguage(AppLanguage language) => _set(
    languageKey,
    _selectableOnly(language).tag,
    _now.copyWith(language: _selectableOnly(language)),
  );

  /// English unless the language is one a rider may pick today.
  ///
  /// Belt and braces: the picker cannot offer a locked language, so nothing
  /// should reach here holding one. It exists because the cost of being wrong
  /// is a rider woken in a voice the app has no clips for, and the cost of
  /// the check is one list lookup.
  static AppLanguage _selectableOnly(AppLanguage language) =>
      language.isSelectable ? language : AppLanguage.english;

  AppSettings get _now => state.valueOrNull ?? const AppSettings();
}

final appSettingsProvider =
    AsyncNotifierProvider<AppSettingsNotifier, AppSettings>(
      AppSettingsNotifier.new,
    );

final ttsLanguageGatewayProvider = Provider<TtsLanguageGateway>(
  (ref) => TtsLanguageGateway(),
);

/// Which languages this device can actually speak. See the gateway for why the
/// picker asks instead of assuming.
final availableLanguagesProvider = FutureProvider<Set<AppLanguage>>(
  (ref) => ref.watch(ttsLanguageGatewayProvider).available(),
);

/// Starts analytics for the UI isolate, once the rider's opt-out is known.
///
/// An app open is the whole implementation of two pre-committed bars, installs
/// and D30 retention: Aptabase derives both from its own anonymous per-device
/// identity, so initialising the SDK IS the measurement. The ride events come
/// from the service isolate instead, because the UI can die mid-ride.
///
/// Depends on the settings read, so the SDK cannot start before the opt-out has
/// been looked at. [Analytics.init] is idempotent, which matters because this
/// re-runs whenever settings change.
final analyticsBootProvider = FutureProvider<void>((ref) async {
  final settings = await ref.watch(appSettingsProvider.future);
  await Analytics.init(
    enabled: settings.shareAnonymousUsage,
    isolate: AnalyticsIsolate.ui,
  );
});
