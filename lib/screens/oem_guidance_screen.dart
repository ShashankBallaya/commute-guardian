import 'package:flutter/material.dart';

import '../services/oem_guidance.dart';
import '../theme/palette.dart';
import '../theme/type_scale.dart';
import '../widgets/pressable.dart';
import '../widgets/primary_button.dart';

/// The screen that tells a rider what their own phone brand does to this app.
///
/// IT IS INSTRUCTIONS, NOT A STATUS, and the difference decides the whole
/// design. Nothing here can be read back: the autostart list has no API, so
/// this screen can never show a green tick and must never pretend to. What it
/// can do is name the rider's phone, give the steps in the skin's own words,
/// open the screen those steps happen on where the platform allows it, and
/// take the rider's word that they have done it. See
/// lib/services/oem_guidance.dart.
///
/// THE CONFIRMATION IS PINNED, THE READING SCROLLS, and that was measured
/// rather than chosen. The first draft put everything in one ListView, and at
/// 360x640 (the 3T, the device every bench runs on) the "I have done this"
/// button was not merely below the fold: it was never built. A rider on a
/// budget Android, which is most of this market, met a screen whose primary
/// action did not exist until they scrolled past five steps. The steps are a
/// document and scroll like one. The confirmation is a control and stays put.
///
/// The deep link sits WITH the steps rather than in the footer, because it is
/// about them: it opens the screen those steps are performed on. Only the
/// answer to "have you done it" is pinned.
///
/// SEEN ONCE, MAYBE TWICE, which is what earns it any motion at all. The steps
/// stagger in (40 ms apart, 240 ms each) off one controller, because a
/// numbered list that assembles reads as a sequence and one that appears whole
/// reads as a wall. It is decorative, and it is gone entirely under reduced
/// motion. Everything else here is press feedback, which the design system
/// already owns.
class OemGuidanceScreen extends StatefulWidget {
  const OemGuidanceScreen({
    super.key,
    required this.guidance,
    required this.onBack,
    required this.onOpenSetting,
    required this.onAcknowledge,
    this.acknowledged = false,
  });

  final OemGuidance guidance;
  final VoidCallback onBack;

  /// Opens the skin's own autostart screen. Answers with the component that
  /// opened, or null when this phone has none that resolve, which this screen
  /// says out loud rather than hiding.
  final Future<String?> Function() onOpenSetting;

  /// The rider says they have done it. Their word, recorded as their word.
  final VoidCallback onAcknowledge;

  final bool acknowledged;

  @override
  State<OemGuidanceScreen> createState() => _OemGuidanceScreenState();
}

class _OemGuidanceScreenState extends State<OemGuidanceScreen> {
  /// Set once the deep link has been tried and this phone had nothing to open.
  /// Null means it has not been tried.
  bool? _deepLinkWorked;

  Future<void> _openSetting() async {
    final opened = await widget.onOpenSetting();
    if (!mounted) return;
    setState(() => _deepLinkWorked = opened != null);
  }

  @override
  Widget build(BuildContext context) {
    final guidance = widget.guidance;
    return Scaffold(
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Header(onBack: widget.onBack),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(22, 4, 22, 20),
                children: [
                  Text(
                    'Your ${guidance.brandLabel} needs one more setting',
                    style: const TextStyle(
                      fontSize: TypeScale.display,
                      letterSpacing: TypeScale.displayTracking,
                      fontWeight: FontWeight.w700,
                      color: Palette.text,
                      height: 1.2,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    // SAYS WHAT IT CANNOT DO. The app already holds every
                    // permission Android offers, so a rider who has granted
                    // them all deserves to know why they are being asked for
                    // something else, and that this one is out of our reach.
                    '${guidance.brandLabel} phones keep a second list that '
                    'decides whether an app may run in the background. The '
                    'app cannot read it or change it, and it can stop Travel '
                    'Mode without telling either of us.',
                    style: TextStyle(
                      fontSize: TypeScale.body,
                      height: 1.5,
                      color: Palette.textDim(0.72),
                    ),
                  ),
                  const SizedBox(height: 22),
                  _StepsCard(steps: guidance.steps),
                  const SizedBox(height: 18),
                  // CROSSFADED, NOT SWAPPED. A control that vanishes and is
                  // replaced by a paragraph in one frame reads as a glitch,
                  // and this particular swap lands the moment a rider has just
                  // pressed something, which is when they are watching hardest.
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 200),
                    switchInCurve: const Cubic(0.23, 1, 0.32, 1),
                    switchOutCurve: const Cubic(0.23, 1, 0.32, 1),
                    child: _deepLinkWorked == false
                        ? Text(
                            key: const Key('oem_open_unavailable'),
                            'This phone will not open that screen directly. '
                            'Follow the steps above by hand.',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: TypeScale.label,
                              height: 1.45,
                              color: Palette.textDim(0.55),
                            ),
                          )
                        : PrimaryButton(
                            key: const Key('oem_open_setting'),
                            label: 'Open the setting',
                            filled: false,
                            onTap: _openSetting,
                          ),
                  ),
                ],
              ),
            ),
            _Confirmation(
              acknowledged: widget.acknowledged,
              onAcknowledge: widget.onAcknowledge,
            ),
          ],
        ),
      ),
    );
  }
}

/// The pinned foot: the one control this screen exists to offer, and the one
/// sentence that keeps it honest.
class _Confirmation extends StatelessWidget {
  const _Confirmation({required this.acknowledged, required this.onAcknowledge});

  final bool acknowledged;
  final VoidCallback onAcknowledge;

  @override
  Widget build(BuildContext context) {
    return Container(
      // A hairline rather than a card, so the foot reads as the edge of the
      // document above it rather than as a fourth surface.
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: Palette.hairline)),
      ),
      padding: const EdgeInsets.fromLTRB(22, 14, 22, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PrimaryButton(
            key: const Key('oem_acknowledge'),
            label: acknowledged ? 'Done' : 'I have done this',
            // WHITE, NOT CRIMSON. Crimson means END A RIDE and nothing else
            // may wear it. White is the primary action of the screen in front
            // of the rider, which this is.
            onTap: onAcknowledge,
            enabled: !acknowledged,
          ),
          const SizedBox(height: 10),
          Text(
            // THE HONEST FOOTNOTE. This is the rider's word and the app
            // records it as exactly that. Writing "verified" here would be the
            // one lie this screen is in a position to tell.
            'The app cannot check this setting. This is your own note.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: TypeScale.caption,
              height: 1.4,
              color: Palette.textDim(0.45),
            ),
          ),
        ],
      ),
    );
  }
}

/// The numbered steps, staggered in off ONE controller.
///
/// One controller with an [Interval] per row, rather than one controller and a
/// delayed start per row. Five controllers and five pending futures is a lot of
/// machinery for a decoration, and the futures outlive a fast back-press: they
/// resolve into a disposed State and are only harmless because every one of
/// them checks `mounted`. An interval cannot outlive the animation it belongs
/// to.
class _StepsCard extends StatefulWidget {
  const _StepsCard({required this.steps});

  final List<String> steps;

  @override
  State<_StepsCard> createState() => _StepsCardState();
}

class _StepsCardState extends State<_StepsCard>
    with SingleTickerProviderStateMixin {
  /// 40 ms between rows (inside the 30 to 80 ms band a stagger reads in) and
  /// 240 ms for each row's own fade. The whole cascade for five steps is
  /// therefore 400 ms, while no single element is on screen for longer than
  /// 240, which is the number that decides whether motion feels quick.
  static const _step = Duration(milliseconds: 40);
  static const _fade = Duration(milliseconds: 240);

  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    final total = _fade + _step * (widget.steps.length - 1);
    _controller = AnimationController(vsync: this, duration: total);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Reduced motion is read here rather than in initState because it is a
    // MediaQuery, and it decides whether this runs at all.
    if (MediaQuery.disableAnimationsOf(context)) {
      _controller.value = 1;
    } else if (!_controller.isAnimating && _controller.value == 0) {
      _controller.forward();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final total = _controller.duration!.inMilliseconds;
    return Container(
      decoration: Palette.glassCard(radius: 20),
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final (index, step) in widget.steps.indexed) ...[
            if (index > 0) const SizedBox(height: 16),
            _Step(
              number: index + 1,
              text: step,
              progress: CurvedAnimation(
                parent: _controller,
                curve: Interval(
                  (_step.inMilliseconds * index) / total,
                  (_step.inMilliseconds * index + _fade.inMilliseconds) / total,
                  // A strong ease-out, the same curve the press feedback uses.
                  // Flutter's stock curves are too soft to read at 240 ms.
                  curve: const Cubic(0.23, 1, 0.32, 1),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _Step extends StatelessWidget {
  const _Step({
    required this.number,
    required this.text,
    required this.progress,
  });

  final int number;
  final String text;
  final Animation<double> progress;

  @override
  Widget build(BuildContext context) {
    // FadeTransition and SlideTransition rather than Opacity and
    // Transform.translate inside an AnimatedBuilder: these two repaint without
    // rebuilding the subtree under them, which is the whole reason Flutter
    // ships them.
    return FadeTransition(
      opacity: progress,
      child: SlideTransition(
        // A fraction of the row's own height, not a hardcoded 8 px, so a step
        // that wraps to three lines rises by the same proportion as one that
        // does not. Never from zero: nothing arrives from nowhere.
        position: Tween<Offset>(
          begin: const Offset(0, 0.25),
          end: Offset.zero,
        ).animate(progress),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 24,
              height: 24,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: Palette.textDim(0.08),
                shape: BoxShape.circle,
              ),
              child: Text(
                '$number',
                style: TextStyle(
                  fontSize: TypeScale.caption,
                  fontWeight: FontWeight.w700,
                  color: Palette.textDim(0.8),
                ),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  text,
                  style: const TextStyle(
                    fontSize: TypeScale.body,
                    height: 1.5,
                    color: Palette.text,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
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
            key: const Key('oem_back'),
            onTap: onBack,
            child: const Padding(
              padding: EdgeInsets.all(8),
              child: Icon(Icons.chevron_left, color: Palette.text, size: 24),
            ),
          ),
          const SizedBox(width: 2),
          // EXPANDED, and it was overflowing without it at every size this app
          // is measured at, 412 px included. A header title is the one string
          // on a screen that cannot be allowed to push a back button off the
          // edge, and a rider at a large text scale meets that first.
          const Expanded(
            child: Text(
              'Keeping Travel Mode alive',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: TypeScale.heading,
                fontWeight: FontWeight.w700,
                color: Palette.text,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
