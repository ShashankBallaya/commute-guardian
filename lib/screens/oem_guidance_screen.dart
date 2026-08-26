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
/// SEEN ONCE, MAYBE TWICE, which is what earns it any motion at all. The steps
/// stagger in as it opens (40 ms apart, 260 ms each), because a numbered list
/// that assembles reads as a sequence and a list that appears whole reads as a
/// wall. That is the only animation here, it is decorative, and it is gone
/// entirely under reduced motion. Everything else on this screen is a press
/// response, which the design system already owns.
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
                padding: const EdgeInsets.fromLTRB(22, 4, 22, 28),
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
                  if (_deepLinkWorked == false)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 14),
                      child: Text(
                        'This phone will not open that screen directly. '
                        'Follow the steps above by hand.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: TypeScale.label,
                          height: 1.45,
                          color: Palette.textDim(0.55),
                        ),
                      ),
                    )
                  else
                    Padding(
                      padding: const EdgeInsets.only(bottom: 14),
                      child: PrimaryButton(
                        key: const Key('oem_open_setting'),
                        label: 'Open the setting',
                        filled: false,
                        onTap: _openSetting,
                      ),
                    ),
                  PrimaryButton(
                    key: const Key('oem_acknowledge'),
                    label: widget.acknowledged
                        ? 'Done'
                        : 'I have done this',
                    // WHITE, NOT CRIMSON. Crimson means END A RIDE and nothing
                    // else may wear it. White is the primary action of the
                    // screen in front of the rider, which this is.
                    onTap: widget.onAcknowledge,
                    enabled: !widget.acknowledged,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    // THE HONEST FOOTNOTE. This is the rider's word and the
                    // app records it as exactly that. Writing "verified" here
                    // would be the one lie this screen could tell.
                    'The app cannot check this setting, so this is your note '
                    'to yourself. You can come back to it from Settings.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: TypeScale.caption,
                      height: 1.45,
                      color: Palette.textDim(0.45),
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
}

/// The numbered steps, staggered in.
class _StepsCard extends StatelessWidget {
  const _StepsCard({required this.steps});

  final List<String> steps;

  @override
  Widget build(BuildContext context) {
    final reduced = MediaQuery.disableAnimationsOf(context);
    return Container(
      decoration: Palette.glassCard(radius: 20),
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final (index, step) in steps.indexed) ...[
            if (index > 0) const SizedBox(height: 16),
            _Step(
              number: index + 1,
              text: step,
              // 40 ms apart. Short enough that the list is assembled before a
              // rider has finished reading the first line, long enough to read
              // as an order rather than a flicker.
              delay: reduced
                  ? Duration.zero
                  : Duration(milliseconds: 40 * index),
              animate: !reduced,
            ),
          ],
        ],
      ),
    );
  }
}

class _Step extends StatefulWidget {
  const _Step({
    required this.number,
    required this.text,
    required this.delay,
    required this.animate,
  });

  final int number;
  final String text;
  final Duration delay;
  final bool animate;

  @override
  State<_Step> createState() => _StepState();
}

class _StepState extends State<_Step> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 260),
  );

  @override
  void initState() {
    super.initState();
    if (!widget.animate) {
      _controller.value = 1;
      return;
    }
    // A DELAY, NOT A TIMER. forward(from:) after a scheduled callback would
    // need cancelling on dispose; an interval on the controller cannot outlive
    // it. The stagger is the delay, and the whole thing is one animation.
    Future<void>.delayed(widget.delay, () {
      if (mounted) _controller.forward();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        // A strong ease-out, the same curve the press feedback uses. Flutter's
        // stock curves are too soft to read at this duration.
        final t = const Cubic(0.23, 1, 0.32, 1).transform(_controller.value);
        return Opacity(
          opacity: t,
          // 8 px, and never from zero: nothing in the real world arrives from
          // nowhere, and a longer rise at this speed reads as a jump.
          child: Transform.translate(offset: Offset(0, 8 * (1 - t)), child: child),
        );
      },
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
              '${widget.number}',
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
                widget.text,
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
          const Text(
            'Keeping Travel Mode alive',
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
