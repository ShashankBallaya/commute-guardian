/// The languages Travel Mode can speak in.
///
/// The tag is what `FlutterTts.setLanguage` is given, and it is also the clip
/// pack's folder name (`clips/en-IN`), so these two things cannot drift.
///
/// NATIVE SCRIPT IN THE LABEL, deliberately. A rider who reads Marathi finds
/// "मराठी" faster than they find "Marathi", and a rider who reads neither is
/// not helped by either.
enum AppLanguage {
  english('en-IN', 'English'),
  hindi('hi-IN', 'हिंदी'),
  marathi('mr-IN', 'मराठी');

  const AppLanguage(this.tag, this.label);

  final String tag;
  final String label;

  static AppLanguage fromTag(String? tag) =>
      AppLanguage.values.firstWhere((l) => l.tag == tag, orElse: () => english);
}

/// Everything the rider has chosen on the Settings screen.
///
/// Stored one key at a time in the AppFlags table, which is already a key and
/// value string table and needed no migration to hold any of this. The
/// settingsProvider the Riverpod design called premature in July arrives here,
/// with the screen, exactly as that document predicted it would.
class AppSettings {
  const AppSettings({
    this.pulseIntervalMinutes = 0,
    this.crowdMode = false,
    this.vibrateWithPulse = true,
    this.announceEveryStation = true,
    this.shareAnonymousUsage = true,
    this.language = AppLanguage.english,
  });

  /// Minutes between Pocket Pulse sounds, or 0 for off.
  ///
  /// OFF BY DEFAULT, and that is a product decision rather than an oversight.
  /// A rider installs this app to be woken at their stop; a chime arriving in
  /// their earphones every three minutes without them having asked for it is a
  /// surprise, and surprises in someone's ears cost uninstalls. Pocket Pulse
  /// introduces itself and then waits to be turned on.
  final int pulseIntervalMinutes;

  /// The handover's "High Alert 45s", renamed to say WHEN you would want it
  /// rather than what it does. Overrides the interval while on.
  final bool crowdMode;

  /// SCOPED TO THE PULSE, and the screen says so out loud.
  ///
  /// A plain "haptics" switch would also silence the wake ladder's vibration
  /// (wake_alert_output.dart), which means a rider could quietly disable half
  /// of the alarm meant to wake them. The wake alarm always vibrates.
  final bool vibrateWithPulse;

  /// Off announces only the destination, and still wakes the rider.
  final bool announceEveryStation;

  /// Aptabase, once it exists. OPT-OUT rather than opt-in, per the locked
  /// monetization design. Stored from day one so the flag is already true or
  /// false by the time there is anything to read it, rather than a switch that
  /// silently controls nothing.
  final bool shareAnonymousUsage;

  /// What Travel Mode speaks in.
  ///
  /// NEVER SET TO SOMETHING THE DEVICE CANNOT SPEAK. The Settings screen only
  /// offers languages `FlutterTts` reports as available, because the failure
  /// mode here is not a cosmetic fallback: an unavailable voice means the wake
  /// alarm's spoken lines do not come out, on the one feature the product
  /// exists for.
  final AppLanguage language;

  /// Seconds between pulses, or null when the pulse is off. Crowd mode wins.
  int? get pulseIntervalSeconds {
    if (crowdMode) return 45;
    if (pulseIntervalMinutes <= 0) return null;
    return pulseIntervalMinutes * 60;
  }

  AppSettings copyWith({
    int? pulseIntervalMinutes,
    bool? crowdMode,
    bool? vibrateWithPulse,
    bool? announceEveryStation,
    bool? shareAnonymousUsage,
    AppLanguage? language,
  }) =>
      AppSettings(
        pulseIntervalMinutes: pulseIntervalMinutes ?? this.pulseIntervalMinutes,
        crowdMode: crowdMode ?? this.crowdMode,
        vibrateWithPulse: vibrateWithPulse ?? this.vibrateWithPulse,
        announceEveryStation: announceEveryStation ?? this.announceEveryStation,
        shareAnonymousUsage: shareAnonymousUsage ?? this.shareAnonymousUsage,
        language: language ?? this.language,
      );
}
