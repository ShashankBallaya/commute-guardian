import 'package:flutter/material.dart';

import '../theme/palette.dart';
import '../theme/type_scale.dart';
import '../widgets/fill_or_scroll.dart';
import '../widgets/primary_button.dart';
import '../widgets/pressable.dart';

/// Screen 3, Preparing. The moment the rider hands the ride over to their
/// pocket.
///
/// THIS SCREEN DOES NOT APPEAR ON A NORMAL RIDE, and that is the design, not a
/// gap. Screen 1 asks for a fix the moment it opens (see HomeScreen._locateOnce),
/// so by the time a destination is picked the fix is usually already held, and
/// what remains (planning the route, building the engines, arming the chain) is
/// milliseconds of on-device work against bundled JSON. A progress screen there
/// would flash and vanish, which is worse than not existing. So this appears
/// only when there is a real wait or a real problem.
///
/// DIRECTION IS NOT A STEP. It cannot resolve until the train has physically
/// crossed a station, which is minutes away and cannot happen on the platform,
/// so it is shown as something that happens later and never gates the exit.
/// Drawn as a pending row it would be a promise the screen cannot keep.
///
/// The route promise sits at the top because it is the contract the rider is
/// about to trust with their sleep, and the last chance to catch a wrong pick.
/// That matters more here than it sounds: Kalyan and Kalwa are one fat-finger
/// apart in the picker, and the failure mode is waking up in the wrong town.
///
/// State A (frame approved 29 Jul 2026) is the wait for a fix, and lives in
/// [PreparingScreen]. State B (cannot locate) is [CannotLocateScreen], frame
/// approved the same day. States C (background location refused) and D
/// (earphones or volume) are specified but not drawn yet.
class PreparingScreen extends StatelessWidget {
  const PreparingScreen({
    super.key,
    required this.originName,
    required this.destinationName,
    required this.steps,
    required this.onCancel,
  });

  /// Null until the fix lands. State A exists precisely because the origin is
  /// not known yet, so the promise cannot assume one.
  final String? originName;
  final String destinationName;

  /// In display order. Progress on the ring is derived from these rather than
  /// timed: we know how many steps are done, so a spinner would be theatre, and
  /// faked progress is not a trade worth making in an app someone sleeps on.
  final List<PrepStep> steps;

  /// The way out. A rider whose fix hangs must never be trapped watching a ring.
  final VoidCallback onCancel;

  /// Real progress, with a step that is IN FLIGHT counted as half.
  ///
  /// Counting only finished steps looked right in a test and was wrong on a
  /// phone (29 Jul 2026): in state A nothing is finished yet, so the ring drew
  /// no arc at all and "Getting ready" sat under an empty circle, which reads
  /// as nothing happening rather than as work under way. Half credit is still
  /// honest, because the step genuinely is part done, and it never invents a
  /// completion the app has not reached.
  double get _progress {
    if (steps.isEmpty) return 0;
    var earned = 0.0;
    for (final step in steps) {
      earned += switch (step.status) {
        PrepStatus.done => 1.0,
        PrepStatus.active => 0.5,
        PrepStatus.pending => 0.0,
      };
    }
    return earned / steps.length;
  }

  @override
  Widget build(BuildContext context) {
    return _PreparingScaffold(
      originName: originName,
      destinationName: destinationName,
      middle: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _ProgressRing(value: _progress),
          const SizedBox(height: 26),
          const Text(
            'Getting ready',
            style: TextStyle(
              fontSize: TypeScale.heading,
              fontWeight: FontWeight.w600,
              color: Palette.text,
            ),
          ),
          const SizedBox(height: 26),
          _StepCard(steps: steps),
        ],
      ),
      bottom: _PlainButton(
        key: const Key('preparing_cancel'),
        label: 'Cancel',
        onTap: onCancel,
      ),
    );
  }
}

/// Screen 3 state B. The fix did not land.
///
/// NOT AN ERROR, and it must not read as one. Standing under a station roof is
/// the ordinary case in Mumbai, and the status chip's own comment calls a single
/// fix attempt "a coin flip indoors on an old phone". The copy therefore says
/// what to DO rather than what went wrong.
///
/// No ring here on purpose: a ring implies progress toward something, and
/// nothing progresses until the rider acts.
class CannotLocateScreen extends StatelessWidget {
  const CannotLocateScreen({
    super.key,
    required this.originName,
    required this.destinationName,
    required this.onRetry,
    required this.onSetStation,
  });

  /// Null until the fix lands. State A exists precisely because the origin is
  /// not known yet, so the promise cannot assume one.
  final String? originName;
  final String destinationName;

  final VoidCallback onRetry;

  /// The escape hatch. The rider always knows which station they are standing
  /// on, even when the phone does not.
  ///
  /// NOTE: this implies a manual origin picker that DOES NOT EXIST yet. Origin
  /// is currently only ever detected, never picked, which is why SavedRoute
  /// stores no origin. The callback is real; what it opens is not built.
  final VoidCallback onSetStation;

  /// The pin red from the state B frame (29 Jul 2026).
  ///
  /// DELIBERATELY LOCAL, not added to [Palette]. It contradicts the palette's
  /// own written rule that there is no status red, settled 28 Jul 2026, so it
  /// stays scoped to this screen until that decision is explicitly reopened.
  /// One line to revert: swap for Palette.textDim(0.35).
  static const _pinRed = Color(0xFFDF4B58);

  @override
  Widget build(BuildContext context) {
    return _PreparingScaffold(
      originName: originName,
      destinationName: destinationName,
      middle: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 78,
            height: 78,
            decoration: BoxDecoration(
              color: Palette.surface,
              shape: BoxShape.circle,
              border: Border.all(color: Palette.hairline),
            ),
            child: const Icon(Icons.place, color: _pinRed, size: 30),
          ),
          const SizedBox(height: 24),
          const Text(
            "We can't find you yet",
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: TypeScale.heading,
              fontWeight: FontWeight.w700,
              color: Palette.text,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            'GPS is slow under a station roof. Move toward a door, or set your '
            "station by hand and we'll take it from there.",
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: TypeScale.label,
              height: 1.45,
              color: Palette.textDim(0.55),
            ),
          ),
        ],
      ),
      bottom: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          PrimaryButton(
            key: const Key('cannot_locate_retry'),
            label: 'Try again',
            onTap: onRetry,
          ),
          const SizedBox(height: 12),
          PrimaryButton(
            key: const Key('cannot_locate_set_station'),
            label: 'Set my station',
            filled: false,
            onTap: onSetStation,
          ),
        ],
      ),
    );
  }
}

/// Screen 3 state C. Background location is refused, so the app cannot do its
/// one job.
///
/// THE ONLY STATE THAT BLOCKS. This is the Android 11+ two-step permission trap
/// where most users silently drop out, and its consequence is exact: with the
/// screen off and the phone in a pocket, nothing watches for the stop.
///
/// THE CONSEQUENCE IS THE HEADLINE, not the permission name. A rider does not
/// care what the setting is called, they care that they will sleep past their
/// stop. The setting names appear in the body, bolded, because that is where
/// they become instructions rather than jargon.
class BackgroundLocationScreen extends StatelessWidget {
  const BackgroundLocationScreen({
    super.key,
    required this.originName,
    required this.destinationName,
    required this.onOpenSettings,
    required this.onStartAnyway,
  });

  /// Null until the fix lands. State A exists precisely because the origin is
  /// not known yet, so the promise cannot assume one.
  final String? originName;
  final String destinationName;

  final VoidCallback onOpenSettings;

  /// Deliberately available and deliberately quiet. Refusing to run would be
  /// worse than running degraded: a rider already on a moving train cannot
  /// always stop to fix settings, and a downgraded ride beats no ride.
  final VoidCallback onStartAnyway;

  @override
  Widget build(BuildContext context) {
    return _PreparingScaffold(
      originName: originName,
      destinationName: destinationName,
      middle: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 78,
            height: 78,
            decoration: BoxDecoration(
              color: Palette.surface,
              shape: BoxShape.circle,
              border: Border.all(color: Palette.hairline),
            ),
            // dotAmber, the palette's existing "needs attention" colour, rather
            // than sampling the frame's orange. They are within a few points of
            // each other and a new token would not have earned its place.
            child: const Icon(Icons.lock, color: Palette.dotAmber, size: 30),
          ),
          const SizedBox(height: 24),
          const Text(
            "We can't wake you with the screen off",
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: TypeScale.heading,
              fontWeight: FontWeight.w700,
              color: Palette.text,
            ),
          ),
          const SizedBox(height: 12),
          Text.rich(
            TextSpan(
              children: const [
                TextSpan(text: 'Location is set to '),
                TextSpan(
                  text: 'While using the app',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
                TextSpan(
                  text:
                      '. To watch for your stop while the phone is in your '
                      'pocket, we need ',
                ),
                TextSpan(
                  text: 'Allow all the time',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
                TextSpan(text: '.'),
              ],
            ),
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: TypeScale.label,
              height: 1.45,
              color: Palette.textDim(0.55),
            ),
          ),
        ],
      ),
      bottom: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          PrimaryButton(
            key: const Key('background_location_settings'),
            label: 'Open settings',
            onTap: onOpenSettings,
          ),
          const SizedBox(height: 4),
          _PlainButton(
            key: const Key('background_location_start_anyway'),
            label: 'Start anyway',
            onTap: onStartAnyway,
          ),
        ],
      ),
    );
  }
}

/// Screen 3 state D. The ride can start, but something will make it worse.
///
/// NEVER BLOCKS. Earphones and volume are warnings, not gates: a speaker alarm
/// still wakes the rider, and refusing to start over a fixable annoyance would
/// be the worse failure. Audio through earphones is the primary channel on both
/// platforms, though, and a muted phone is a silent alarm with a cause anyone
/// can fix in the ten seconds before they sit down.
///
/// ONLY WHAT IS ACTUALLY WRONG GETS LISTED. If the earphones are in and the
/// volume is up, this state does not exist and the rider never sees a checklist
/// at all. The headline COUNTS the warnings, so it must never be hardcoded.
class PreflightScreen extends StatelessWidget {
  const PreflightScreen({
    super.key,
    required this.originName,
    required this.destinationName,
    required this.steps,
    required this.onStart,
    required this.onRecheck,
  });

  /// Null until the fix lands. State A exists precisely because the origin is
  /// not known yet, so the promise cannot assume one.
  final String? originName;
  final String destinationName;

  /// Warnings carry [PrepStatus.active]; the reassuring row that the stop is
  /// being watched carries [PrepStatus.done]. A card of pure bad news would
  /// misrepresent a ride that is about to work.
  final List<PrepStep> steps;

  final VoidCallback onStart;

  /// "I've fixed it, check again". Cheaper than making the rider guess whether
  /// plugging in mid-screen registered.
  final VoidCallback onRecheck;

  int get _warningCount =>
      steps.where((s) => s.status == PrepStatus.active).length;

  /// Counted, never hardcoded. The frame said "Two things" because it happened
  /// to draw two; one earphone warning alone must not say "Two".
  static String headlineFor(int warnings) => switch (warnings) {
    0 => 'Before you doze off',
    1 => 'One thing before you doze off',
    2 => 'Two things before you doze off',
    3 => 'Three things before you doze off',
    _ => '$warnings things before you doze off',
  };

  @override
  Widget build(BuildContext context) {
    return _PreparingScaffold(
      originName: originName,
      destinationName: destinationName,
      middle: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            headlineFor(_warningCount),
            style: const TextStyle(
              fontSize: TypeScale.heading,
              fontWeight: FontWeight.w700,
              color: Palette.text,
            ),
          ),
          const SizedBox(height: 16),
          _StepCard(steps: steps, boldLabels: true),
        ],
      ),
      bottom: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          PrimaryButton(
            key: const Key('preflight_start'),
            label: 'Start the ride',
            onTap: onStart,
          ),
          const SizedBox(height: 4),
          _PlainButton(
            key: const Key('preflight_recheck'),
            label: "I've fixed it, check again",
            onTap: onRecheck,
          ),
        ],
      ),
    );
  }
}

/// The shared skeleton: promise pinned to the top, content centred in what is
/// left, actions in the thumb zone. The bottom-anchored rule is about where
/// ACTIONS go, which is why state A's Cancel and state B's buttons both sit
/// here while the reading matter floats.
class _PreparingScaffold extends StatelessWidget {
  const _PreparingScaffold({
    required this.originName,
    required this.destinationName,
    required this.middle,
    required this.bottom,
  });

  /// Null until the fix lands. State A exists precisely because the origin is
  /// not known yet, so the promise cannot assume one.
  final String? originName;
  final String destinationName;
  final Widget middle;
  final Widget bottom;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(22, 16, 22, 26),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _Promise(
                originName: originName,
                destinationName: destinationName,
              ),
              // Centred while it fits, scrollable when it does not. The step
              // card grows with the font size and the promise above it grows
              // with the station name, which together ran 56 px past the
              // bottom of a 320 dp phone (measured 5 Aug 2026). Cancel stays
              // outside, always reachable: a rider whose fix hangs must never
              // have to scroll to get out.
              Expanded(
                child: FillOrScroll(child: Center(child: middle)),
              ),
              bottom,
            ],
          ),
        ),
      ),
    );
  }
}

/// Full-width action. [filled] is the white primary from the state B frame.
///
/// White, not crimson, and that turns out to be RIGHT by the locked rule rather
/// than in spite of it: crimson is reserved for the action that starts or ends
/// a journey, and Try again retries a fix. It does introduce a surface this app
/// has not used before, so it is worth deciding whether it is the app's primary
/// button everywhere or only here.

/// A text-only action. Available, never encouraged: this is the shape for the
/// choice we would rather the rider did not make (Start anyway) and for the one
/// that simply leaves (Cancel).
class _PlainButton extends StatelessWidget {
  const _PlainButton({super.key, required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Pressable(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 14),
        child: Center(
          child: Text(
            label,
            style: TextStyle(
              fontSize: TypeScale.body,
              color: Palette.textDim(0.5),
            ),
          ),
        ),
      ),
    );
  }
}

/// What a step is doing right now.
enum PrepStatus {
  /// Finished. Counts toward the ring.
  done,

  /// Working on it. At most one of these, and it carries the amber dot.
  active,

  /// Not started, or (for direction) not startable yet.
  pending,
}

class PrepStep {
  const PrepStep({required this.label, this.detail, required this.status});

  final String label;

  /// The quiet second line. Used to set an expectation the rider would
  /// otherwise have to guess at, e.g. that a fix is slow indoors.
  final String? detail;

  final PrepStatus status;
}

/// The contract, stated in the rider's words.
class _Promise extends StatelessWidget {
  const _Promise({required this.originName, required this.destinationName});

  /// Null until the fix lands. State A exists precisely because the origin is
  /// not known yet, so the promise cannot assume one.
  final String? originName;
  final String destinationName;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text.rich(
          TextSpan(
            children: [
              // Before the fix lands there is no origin to name, so the promise
              // states the half we DO know rather than inventing the other.
              if (originName == null)
                const TextSpan(text: 'To ')
              else ...[
                TextSpan(text: originName),
                // Arrow, never a dash, per the project copy rule.
                TextSpan(
                  text: '  →  ',
                  style: TextStyle(color: Palette.textDim(0.45)),
                ),
              ],
              TextSpan(text: destinationName),
            ],
          ),
          style: const TextStyle(
            fontSize: TypeScale.title,
            fontWeight: FontWeight.w700,
            color: Palette.text,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          "We'll wake you up before $destinationName.",
          style: TextStyle(
            fontSize: TypeScale.label,
            color: Palette.textDim(0.62),
          ),
        ),
      ],
    );
  }
}

/// Determinate, and animated between real values rather than spun.
class _ProgressRing extends StatelessWidget {
  const _ProgressRing({required this.value});

  final double value;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 110,
      height: 110,
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: value),
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOutCubic,
        builder: (context, animated, _) => CircularProgressIndicator(
          value: animated,
          strokeWidth: 7,
          strokeCap: StrokeCap.round,
          backgroundColor: Palette.textDim(0.09),
          valueColor: const AlwaysStoppedAnimation(Palette.dotGreen),
        ),
      ),
    );
  }
}

class _StepCard extends StatelessWidget {
  const _StepCard({required this.steps, this.boldLabels = false});

  final List<PrepStep> steps;

  /// State D bolds its rows: each one is a thing to act on, not a status to
  /// watch. State A's are progress and stay quiet.
  final bool boldLabels;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: Palette.glassCard(radius: 18),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < steps.length; i++) ...[
            if (i > 0) const SizedBox(height: 12),
            _StepRow(step: steps[i], bold: boldLabels),
          ],
        ],
      ),
    );
  }
}

class _StepRow extends StatelessWidget {
  const _StepRow({required this.step, this.bold = false});

  final PrepStep step;
  final bool bold;

  @override
  Widget build(BuildContext context) {
    final (dotColor, labelOpacity) = switch (step.status) {
      PrepStatus.done => (Palette.dotGreen, 0.92),
      PrepStatus.active => (Palette.dotAmber, 0.92),
      PrepStatus.pending => (Palette.textDim(0.22), 0.45),
    };

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: dotColor, shape: BoxShape.circle),
          ),
        ),
        const SizedBox(width: 11),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                step.label,
                style: TextStyle(
                  fontSize: TypeScale.label,
                  fontWeight: bold ? FontWeight.w600 : FontWeight.w400,
                  color: Palette.textDim(labelOpacity),
                ),
              ),
              if (step.detail != null) ...[
                const SizedBox(height: 2),
                Text(
                  step.detail!,
                  style: TextStyle(
                    fontSize: TypeScale.caption,
                    color: Palette.textDim(0.45),
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}
