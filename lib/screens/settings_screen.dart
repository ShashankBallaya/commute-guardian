import 'package:flutter/material.dart';

import '../models/app_settings.dart';
import '../theme/palette.dart';
import '../theme/type_scale.dart';
import '../widgets/pressable.dart';

/// Whether a readiness item is satisfied. Not an error state: an unmet item is
/// something to fix, not something that has gone wrong, and the palette has no
/// status red for exactly that reason.
///
/// [checking] exists because these values come from the platform now and arrive
/// a frame or two late. THE CARD MAY NOT GUESS IN THE MEANTIME. Defaulting to
/// ok would tell a rider whose location is revoked that they are ready, and
/// defaulting to needsAttention would send a rider who is fine hunting for a
/// setting. A dim dot and no detail says the honest thing, which is nothing yet.
enum ReadinessState { ok, needsAttention, checking }

/// One row of the readiness card.
class ReadinessItem {
  const ReadinessItem({
    required this.label,
    required this.state,
    this.detail,
    this.onFix,
  });

  final String label;
  final ReadinessState state;

  /// What goes wrong if it stays unmet. Only shown when it is unmet, because a
  /// satisfied item needs no explanation.
  final String? detail;
  final VoidCallback? onFix;
}

/// Screen 6, Settings. The screen Pocket Pulse has been waiting for.
///
/// Nothing here is crimson. Crimson starts or ends a JOURNEY, and no control on
/// this screen does either, so the palette's one accent simply does not appear.
///
/// THREE ITEMS FROM THE HANDOVER'S SCREEN 6 LIST ARE DELIBERATELY ABSENT, and
/// they are worth naming so nobody adds them back as an oversight:
///
///   - The wake "stations before" stepper. Nothing may become a second way to
///     change leadTimeS, which is locked at 90 s, and two controls for one
///     behaviour is the same disease as two projectors for one position. This
///     used to say "Screen 4's WakeChoice toggle already owns that choice"; that
///     toggle was REMOVED on 11 Aug 2026 because it owned nothing and changed
///     nothing. Choosing the distance is where the stepper belongs when Guardian
///     Plus exists, on THIS screen, before a ride rather than during one.
///   - Alarm volume behaviour. The ladder is [0.3, 0.6, 1.0] and climbs until
///     acknowledged. A volume control's only function would be to make the alarm
///     worse at the single job this product exists to do.
///   - A plain haptics toggle. `vibration` is wired into the wake ladder through
///     wake_alert_output.dart, so one switch would let a rider quietly disable
///     part of their own alarm. It is scoped to the pulse instead, and the
///     caption states the guarantee rather than leaving it to be discovered.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({
    super.key,
    required this.settings,
    required this.readiness,
    required this.availableLanguages,
    required this.versionLine,
    required this.onBack,
    required this.onPulseInterval,
    required this.onCrowdMode,
    required this.onVibrateWithPulse,
    required this.onAnnounceEveryStation,
    required this.onShareAnonymousUsage,
    required this.onLanguage,
    this.onPreviewPulse,
    this.onVersionLongPress,
    this.onSendRideLog,
  });

  final AppSettings settings;
  final List<ReadinessItem> readiness;

  /// Only what the device can actually speak. See TtsLanguageGateway: offering
  /// a language with no voice behind it silences the wake alarm.
  final Set<AppLanguage> availableLanguages;

  /// "Commute Guardian 1.0.0 (1)". The line every support conversation starts
  /// with, and this app already has a false-positive antivirus problem.
  final String versionLine;

  final VoidCallback onBack;
  final ValueChanged<int> onPulseInterval;
  final ValueChanged<bool> onCrowdMode;
  final ValueChanged<bool> onVibrateWithPulse;
  final ValueChanged<bool> onAnnounceEveryStation;
  final ValueChanged<bool> onShareAnonymousUsage;
  final ValueChanged<AppLanguage> onLanguage;
  final VoidCallback? onPreviewPulse;

  /// Opens the share sheet on the rider's recent ride logs. Null hides the row
  /// entirely, which is what a widget test that does not care gets.
  final VoidCallback? onSendRideLog;

  /// The way back to the debug screen, hidden under a long press on the version
  /// line, which is where a dev door has always belonged and where no rider will
  /// find it by accident.
  ///
  /// The debug screen is DEMOTED, never deleted: every bench in this project
  /// runs through it, and the ride that has to verify the whole build is still
  /// ahead of us.
  final VoidCallback? onVersionLongPress;

  static const _intervals = [0, 2, 3, 5, 10];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Header(onBack: onBack),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(22, 4, 22, 28),
                children: [
                  _readinessCard(),
                  const SizedBox(height: 16),
                  _pulseCard(),
                  const SizedBox(height: 16),
                  _announcementsCard(),
                  const SizedBox(height: 16),
                  _privacyCard(),
                  if (onSendRideLog != null) ...[
                    const SizedBox(height: 16),
                    _rideLogCard(),
                  ],
                  const SizedBox(height: 20),
                  Center(
                    child: GestureDetector(
                      onLongPress: onVersionLongPress,
                      // Opaque, so the press lands on the padding around a
                      // short line of text rather than only on the glyphs.
                      behavior: HitTestBehavior.opaque,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Text(
                          versionLine,
                          style: TextStyle(
                            fontSize: TypeScale.caption,
                            color: Palette.textDim(0.4),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// FIRST ON THE SCREEN, and that is a departure from the handover, which had
  /// battery optimisation last as a footnote. OEM battery killers are this
  /// project's own named top product risk and the Android 11 background
  /// location flow is where riders silently drop out. A rider whose app was
  /// killed mid journey has no other way to find out.
  Widget _readinessCard() => _Card(
    title: 'Travel Mode readiness',
    subtitle:
        'What the app needs to wake you while your phone is locked '
        'in a pocket.',
    children: [
      for (final (index, item) in readiness.indexed) ...[
        if (index > 0) const _Divider(),
        _ReadinessRow(item: item),
      ],
    ],
  );

  Widget _pulseCard() => _Card(
    title: 'Pocket Pulse',
    // "with you", not "in your pocket". Many riders carry the phone in a
    // bag, and the pulse never proved possession anyway: it proves the
    // audio link is alive to wherever the phone is. The old copy quietly
    // excluded the bag carriers it actually serves.
    //
    // AND IT NAMES THE SPEAKER, because the code has always used it and this
    // copy used to promise earphones only. With no earphones the chime plays
    // out loud, which the 9 Aug 2026 ride did for two hours and 98 chimes
    // (decision 2 in docs/design/pocket-pulse.md, answered by that ride). A
    // rider about to sit in a quiet carriage is owed that sentence BEFORE they
    // switch it on, not at the first chime.
    subtitle:
        'A quiet sound, in your earphones or out loud, so you know your '
        'phone is still with you without checking.',
    children: [
      _Segmented(
        labels: [for (final m in _intervals) m == 0 ? 'Off' : '$m min'],
        selected: _intervals.indexOf(settings.pulseIntervalMinutes),
        onChanged: (i) => onPulseInterval(_intervals[i]),
      ),
      const SizedBox(height: 4),
      _SwitchRow(
        label: 'Crowd mode',
        detail: 'Every 45 seconds. For a packed train.',
        value: settings.crowdMode,
        onChanged: onCrowdMode,
        switchKey: const Key('settings_crowd_mode'),
      ),
      // SHOWN ON BOTH PLATFORMS AGAIN since 12 Aug 2026, and the history is
      // worth keeping because the reasoning was right twice.
      //
      // It was hidden on iOS on 11 Aug because iOS was believed to forbid
      // background haptics, so PulseOutput.buzz returned at its first line
      // there and this switch could never do anything on an iPhone. A control
      // that cannot work is worse than an absent one. That was proven on the
      // device rather than assumed, by a 10 Aug 2026 iPhone ride log that
      // recorded "PULSE every 45s, with vibration" for a buzz that never
      // happened.
      //
      // `docs/adr/0003` then measured an iPhone buzzing 7 of 7 times from a
      // locked pocket, so the premise is gone and the switch does something on
      // both platforms. Hiding it now would leave every iPhone rider buzzing
      // every 45 seconds with no way to stop it, which is the same fault as
      // the dead control with the sign reversed: last time the switch could
      // not act, this time the rider could not.
      //
      // The row itself was never written as a platform allow-list, which is
      // why re-showing it is a deleted condition rather than an edit. When it
      // is gated at all, gate it as `!Platform.isIOS` and never as
      // `Platform.isAndroid`: the two are identical on the two platforms this
      // app ships to and differ where it is tested, so an allow-list would
      // hide the row from the widget-test host and quietly stop checking it.
      //
      // It lives INSIDE this card rather than in one of its own. It is scoped
      // to the pulse, and position makes that scope self-evident where a
      // caption alone had to be read and believed.
      const _Divider(),
      _SwitchRow(
        label: 'Vibrate with the pulse',
        detail: 'The wake alarm always vibrates.',
        value: settings.vibrateWithPulse,
        onChanged: onVibrateWithPulse,
        switchKey: const Key('settings_vibrate'),
      ),
      if (onPreviewPulse != null) ...[
        const _Divider(),
        Pressable(
          key: const Key('settings_preview_pulse'),
          onTap: onPreviewPulse!,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Row(
              children: [
                const Expanded(
                  child: Text(
                    'Hear it now',
                    style: TextStyle(
                      fontSize: TypeScale.body,
                      color: Palette.text,
                    ),
                  ),
                ),
                Icon(
                  Icons.chevron_right,
                  size: 18,
                  color: Palette.textDim(0.45),
                ),
              ],
            ),
          ),
        ),
      ],
    ],
  );

  Widget _announcementsCard() => _Card(
    title: 'Announcements',
    children: [
      _SwitchRow(
        label: 'Name every station',
        // WIRED 12 Aug 2026, and the copy caught up with it the same day. It
        // said "only your stop"; the code also keeps INTERCHANGES and the
        // overshoot, because both are stations the rider has to act at. Saying
        // only the stop would make the switch sound more drastic than it is.
        detail:
            'Off announces only your stop and any train change, '
            'and still wakes you.',
        value: settings.announceEveryStation,
        onChanged: onAnnounceEveryStation,
        switchKey: const Key('settings_announce_every'),
      ),
      const _Divider(),
      _LanguagePicker(
        available: availableLanguages,
        selected: settings.language,
        onChanged: onLanguage,
      ),
    ],
  );

  Widget _privacyCard() => _Card(
    title: 'Privacy',
    children: [
      _SwitchRow(
        label: 'Share anonymous usage',
        detail: 'Never your location, and never where you travel.',
        value: settings.shareAnonymousUsage,
        onChanged: onShareAnonymousUsage,
        switchKey: const Key('settings_share_usage'),
      ),
    ],
  );

  /// THE ONLY WAY A RIDE THAT WENT WRONG ON SOMEBODY ELSE'S PHONE CAN REACH US.
  ///
  /// It sits next to Privacy and directly above the version line, which is the
  /// pair a support conversation needs: what the app did, and which build did
  /// it. See RideLogExport for why a share sheet and not a folder.
  ///
  /// THE SUBTITLE SAYS WHAT IS IN THE FILE BEFORE THE RIDER SENDS IT. The log
  /// names every station they passed and when. That is theirs, this screen
  /// gives it away in one tap, and the Privacy card one above promises we never
  /// take where they travel. The promise holds only because THEY choose the
  /// share, so the sentence that tells them what they are choosing is not
  /// optional copy.
  Widget _rideLogCard() => _Card(
    title: 'Ride log',
    subtitle:
        'If a station was missed or the alarm did not wake you, send this '
        'and we can see what the app did. It lists the stations you passed '
        'and the times.',
    children: [
      Pressable(
        key: const Key('settings_send_ride_log'),
        onTap: onSendRideLog!,
        child: Padding(
          // 14 rather than the 10 used above it, to clear the 48 dp touch
          // floor on its own. A guard test in settings_screen_test holds it.
          padding: const EdgeInsets.symmetric(vertical: 14),
          child: Row(
            children: [
              const Expanded(
                child: Text(
                  'Send the last ride log',
                  style: TextStyle(
                    fontSize: TypeScale.body,
                    color: Palette.text,
                  ),
                ),
              ),
              Icon(Icons.chevron_right, size: 18, color: Palette.textDim(0.45)),
            ],
          ),
        ),
      ),
    ],
  );
}

class _Header extends StatelessWidget {
  const _Header({required this.onBack});

  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 22, 10),
      child: Row(
        children: [
          Pressable(
            key: const Key('settings_back'),
            onTap: onBack,
            child: const Padding(
              padding: EdgeInsets.all(8),
              child: Icon(Icons.chevron_left, color: Palette.text, size: 24),
            ),
          ),
          const SizedBox(width: 2),
          const Text(
            'Settings',
            style: TextStyle(
              fontSize: TypeScale.heading,
              fontWeight: FontWeight.w700,
              color: Palette.text,
            ),
          ),
        ],
      ),
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.title, required this.children, this.subtitle});

  final String title;
  final String? subtitle;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final subtitle = this.subtitle;
    return Container(
      decoration: Palette.glassCard(radius: 20),
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            title,
            style: const TextStyle(
              fontSize: TypeScale.bodyLarge,
              fontWeight: FontWeight.w700,
              color: Palette.text,
            ),
          ),
          if (subtitle != null) ...[
            const SizedBox(height: 3),
            Text(
              subtitle,
              style: TextStyle(
                fontSize: TypeScale.caption,
                height: 1.45,
                color: Palette.textDim(0.6),
              ),
            ),
          ],
          const SizedBox(height: 12),
          ...children,
        ],
      ),
    );
  }
}

class _Divider extends StatelessWidget {
  const _Divider();

  @override
  Widget build(BuildContext context) => Container(
    height: 1,
    margin: const EdgeInsets.symmetric(vertical: 4),
    color: Palette.hairline,
  );
}

class _ReadinessRow extends StatelessWidget {
  const _ReadinessRow({required this.item});

  final ReadinessItem item;

  @override
  Widget build(BuildContext context) {
    // Only an item KNOWN to be unmet shows a detail and a Fix. A row still
    // being read shows neither: there is nothing to explain and nothing to
    // send the rider to yet.
    final unmet = item.state == ReadinessState.needsAttention;
    final detail = unmet ? item.detail : null;
    final onFix = unmet ? item.onFix : null;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        // TOP aligned, not centre. On a row with a wrapped detail line a
        // centred dot lands in the gap between the label and the detail and
        // reads as pointing at the wrong one.
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            // Optically centres the dot on the label's first line.
            padding: const EdgeInsets.only(top: 6),
            child: Container(
              width: 9,
              height: 9,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                // FLAT, no glow. The glow is the locked "live, tracking now"
                // signal and belongs to the position dot alone; a permission
                // is a state, not a live reading.
                color: switch (item.state) {
                  ReadinessState.ok => Palette.dotGreen,
                  ReadinessState.needsAttention => Palette.dotAmber,
                  // Neither colour, because neither answer is known.
                  ReadinessState.checking => Palette.textDim(0.22),
                },
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.label,
                  style: const TextStyle(
                    fontSize: TypeScale.body,
                    color: Palette.text,
                  ),
                ),
                if (detail != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    detail,
                    style: TextStyle(
                      fontSize: TypeScale.caption,
                      height: 1.4,
                      color: Palette.textDim(0.55),
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (onFix != null) ...[
            const SizedBox(width: 10),
            Pressable(
              key: Key('settings_fix_${item.label}'),
              onTap: onFix,
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(11),
                  border: Border.all(color: Palette.textDim(0.25)),
                ),
                padding: const EdgeInsets.symmetric(
                  horizontal: 15,
                  vertical: 7,
                ),
                child: const Text(
                  'Fix',
                  style: TextStyle(
                    fontSize: TypeScale.label,
                    fontWeight: FontWeight.w600,
                    color: Palette.text,
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _SwitchRow extends StatelessWidget {
  const _SwitchRow({
    required this.label,
    required this.value,
    required this.onChanged,
    required this.switchKey,
    this.detail,
  });

  final String label;
  final String? detail;
  final bool value;
  final ValueChanged<bool> onChanged;
  final Key switchKey;

  @override
  Widget build(BuildContext context) {
    final detail = this.detail;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: const TextStyle(
                    fontSize: TypeScale.body,
                    color: Palette.text,
                  ),
                ),
                if (detail != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    detail,
                    style: TextStyle(
                      fontSize: TypeScale.caption,
                      height: 1.4,
                      color: Palette.textDim(0.55),
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 12),
          Switch(
            key: switchKey,
            value: value,
            onChanged: onChanged,
            activeThumbColor: Palette.dotGreen,
            activeTrackColor: Palette.greenSoft,
          ),
        ],
      ),
    );
  }
}

/// The interval control, in the app's locked selected-segment language: green
/// TEXT on a soft green wash, never a loud fill.
class _Segmented extends StatelessWidget {
  const _Segmented({
    required this.labels,
    required this.selected,
    required this.onChanged,
    this.enabled,
    this.keyPrefix = 'settings_interval',
  });

  final List<String> labels;
  final int selected;
  final ValueChanged<int> onChanged;

  /// Which segments a press may move, or null when every one of them may.
  ///
  /// A DISABLED SEGMENT IS STILL DRAWN, dimmer and not pressable. That is the
  /// point of it: the language picker uses this to show Hindi and Marathi as
  /// coming rather than to pretend they do not exist.
  final List<bool>? enabled;

  /// The widget key stem, because two of these live on this screen and both
  /// used to answer to `settings_interval_0`.
  final String keyPrefix;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(13),
        border: Border.all(color: Palette.hairline),
      ),
      child: Row(
        children: [
          for (final (i, label) in labels.indexed)
            Expanded(
              // IgnorePointer AND NOT A NULL CALLBACK, because Pressable takes
              // a required one and, more to the point, it animates on press.
              // A locked segment that still dips under the thumb reads as
              // broken rather than as not yet.
              child: IgnorePointer(
                ignoring: !(enabled?[i] ?? true),
                child: Pressable(
                key: Key('${keyPrefix}_$i'),
                onTap: () => onChanged(i),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  curve: const Cubic(0.23, 1, 0.32, 1),
                  decoration: BoxDecoration(
                    color: i == selected
                        ? Palette.greenSoft
                        : Palette.greenSoft.withValues(alpha: 0),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  child: Center(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.clip,
                      style: TextStyle(
                        fontSize: TypeScale.label,
                        fontWeight: i == selected
                            ? FontWeight.w700
                            : FontWeight.w400,
                        color: i == selected
                            ? Palette.dotGreen
                            : Palette.textDim(
                                (enabled?[i] ?? true) ? 0.75 : 0.3,
                              ),
                      ),
                    ),
                  ),
                ),
              ),
              ),
            ),
        ],
      ),
    );
  }
}

/// The language picker.
///
/// LOCKED TO ENGLISH FOR THE CLOSED BETA (19 Aug 2026) and still showing all
/// three. The lock is about audio, not strings: only English has a clip pack
/// bundled in the app, and a Hindi rider would hear the wake ladder in the
/// device TTS voice the Sarvam work exists to replace. AppLanguage.selectable
/// carries the full reasoning and is the one place to change it back.
///
/// SHOWN, NOT HIDDEN, because "coming soon" is information a commuter deciding
/// on this app wants and a hidden row cannot give them. Also because these two
/// languages are most of why this product is for Mumbai at all: a rider who
/// sees only English may reasonably conclude it was never built for them.
///
/// WHAT THIS REPLACED, and why it is not a regression: the picker used to
/// offer whatever voices TtsLanguageGateway found on the phone, and say
/// "This phone can only speak English" when it found one. That rule was
/// right and is now simply not the binding one. The gateway still runs and
/// [SettingsScreen.availableLanguages] still carries its answer, because it
/// becomes the binding rule again the moment a second pack ships: a language
/// with clips but no device voice still cannot speak the dynamic lines.
class _LanguagePicker extends StatelessWidget {
  const _LanguagePicker({
    required this.available,
    required this.selected,
    required this.onChanged,
  });

  /// What the device can speak. Not what is offered today: see the class
  /// comment. Kept plumbed because it is the rule that returns.
  final Set<AppLanguage> available;

  final AppLanguage selected;
  final ValueChanged<AppLanguage> onChanged;

  @override
  Widget build(BuildContext context) {
    const offered = AppLanguage.values;
    final locked = offered
        .where((l) => !l.isSelectable)
        .map((l) => l.label)
        .toList(growable: false);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Voice',
            style: TextStyle(fontSize: TypeScale.body, color: Palette.text),
          ),
          const SizedBox(height: 10),
          _Segmented(
            keyPrefix: 'settings_language',
            labels: [for (final l in offered) l.label],
            selected: offered.indexOf(selected).clamp(0, offered.length - 1),
            enabled: [for (final l in offered) l.isSelectable],
            onChanged: (i) => onChanged(offered[i]),
          ),
          if (locked.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(
              // Names them in their own scripts, which is how they are drawn
              // in the control right above this line, so the sentence and the
              // thing it explains cannot be read as two different lists.
              '${locked.join(' and ')} are coming soon. '
              'Every announcement is in English for now.',
              style: TextStyle(
                fontSize: TypeScale.caption,
                height: 1.4,
                color: Palette.textDim(0.55),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
