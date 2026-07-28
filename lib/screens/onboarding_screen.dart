import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/permissions_gateway.dart';
import '../state/ride_providers.dart';
import '../theme/palette.dart';
import '../widgets/mini_rail.dart';

final permissionsGatewayProvider =
    Provider<PermissionsGateway>((ref) => const PermissionsGateway());

/// Onboarding. Six screens, and only the first is about persuasion.
///
/// The rest exist because THE PERMISSIONS ARE THE PRODUCT: without background
/// location this app stops watching the moment the screen goes off, which is
/// exactly when a sleeping rider needs it. Nobody outside the owner's two
/// phones can grant that correctly without being walked through it.
///
/// Every step is skippable. A rider who refuses everything still gets an app
/// that works while they are looking at it, and refusing is not a dead end.
class OnboardingScreen extends ConsumerStatefulWidget {
  const OnboardingScreen({super.key, required this.onDone});

  final VoidCallback onDone;

  @override
  ConsumerState<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends ConsumerState<OnboardingScreen> {
  static const _stops = 6;
  int _step = 0;
  bool _busy = false;

  PermissionsGateway get _permissions => ref.read(permissionsGatewayProvider);

  void _next() {
    if (_step == _stops - 1) {
      widget.onDone();
      return;
    }
    setState(() => _step++);
  }

  /// Runs a permission request, then moves on WHETHER OR NOT IT WAS GRANTED.
  ///
  /// Refusing is a legitimate answer and must not trap the rider on a screen.
  /// The app degrades; it does not stop.
  Future<void> _ask(Future<void> Function() request) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await request();
    } catch (_) {
      // No plugin (tests) or a platform that refuses to answer. Moving on is
      // the safe reading: the ride path re-asks anyway.
    }
    if (!mounted) return;
    setState(() => _busy = false);
    _next();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              MiniRail(stops: _stops, current: _step),
              // Bottom-anchored while the copy is short, SCROLLABLE when it is
              // not. The disclosure screen is long by law rather than by
              // choice (Play requires what, why and that it is background), and
              // on the 3T a fixed spacer pushed it 81 pixels off the bottom,
              // taking the skip button with it.
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) => SingleChildScrollView(
                    child: ConstrainedBox(
                      constraints:
                          BoxConstraints(minHeight: constraints.maxHeight),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          switch (_step) {
                            0 => _welcome(),
                            1 => _disclosure(),
                            2 => _background(),
                            3 => _notifications(),
                            4 => _battery(),
                            _ => _ready(),
                          },
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _welcome() => _Panel(
          key: const Key('onboarding_welcome'),
          heading: 'Never miss your station',
          body: "Sleep, read, scroll. We'll wake you at your destination.",
          action: 'Get started',
          onAction: _next,
        );

  /// Play requires this BEFORE the runtime prompt: what is accessed, why, that
  /// it happens in the background, and an affirmative action. A screen that
  /// only says "we need location" is a rejection.
  Widget _disclosure() => _Panel(
          key: const Key('onboarding_disclosure'),
          heading: 'We watch the line so you do not have to',
          body: 'Commute Guardian uses your location in the background, with '
              'the screen off and the app closed, to announce each station and '
              'wake you before your stop.\n\n'
              'Your location never leaves your phone. There is no account and '
              'no server.',
          action: 'Continue',
          onAction: () => _ask(_permissions.requestWhileInUse),
          quiet: 'Not now',
          onQuiet: _next,
        );

  /// The drop-out point, and the reason onboarding cannot be one screen. On
  /// Android 11+ "Allow all the time" is not offered in the same dialog: the
  /// rider gets foreground only, and background is a separate trip to
  /// Settings. Most never finish it, and the app silently becomes useless on a
  /// locked phone.
  Widget _background() => _Panel(
          key: const Key('onboarding_background'),
          heading: 'One more tap, and you can pocket the phone',
          body: 'Android asks for this separately. Without it we stop watching '
              'the moment your screen goes off, which is exactly when you need '
              'us.',
          action: 'Open settings',
          onAction: () => _ask(_permissions.openSettings),
          // The label they are hunting for is Android's, not ours.
          caption: 'Choose "Allow all the time"',
          quiet: 'Not now',
          onQuiet: _next,
        );

  Widget _notifications() => _Panel(
          key: const Key('onboarding_notifications'),
          heading: 'The controls live in your notifications',
          body: 'While a journey runs we keep one notification up. It is how '
              'you end a ride or keep tracking a little longer without '
              'unlocking the phone.',
          action: 'Allow notifications',
          onAction: () => _ask(_permissions.requestNotifications),
          quiet: 'Not now',
          onQuiet: _next,
        );

  /// Android only. The 3T's own logs record the permission picture at every
  /// ride start precisely because this one decides whether the ride survives a
  /// locked screen.
  Widget _battery() {
    if (!_permissions.isAndroid) {
      // Nothing to ask on iOS. Skip rather than show an empty promise.
      WidgetsBinding.instance.addPostFrameCallback((_) => _next());
      return const SizedBox.shrink();
    }
    return _Panel(
      key: const Key('onboarding_battery'),
      heading: 'Let us keep running while you doze',
      body: 'Some phones put background apps to sleep to save power. We need '
          'an exception, or we may be stopped before your stop.',
      action: 'Allow',
      onAction: () => _ask(
        ref.read(rideServiceClientProvider).requestBatteryOptimizationExemption,
      ),
      quiet: 'Not now',
      onQuiet: _next,
    );
  }

  Widget _ready() => _Panel(
          key: const Key('onboarding_ready'),
          heading: 'You are set',
          body: 'Pick where you are going and put the phone away. We will take '
              'it from here.',
          action: 'Start',
          onAction: _next,
        );
}

/// The one shape every onboarding screen wears: dead space at the top, the
/// panel and its action in the thumb zone. Approved on the welcome screen,
/// 28 Jul 2026.
class _Panel extends StatelessWidget {
  const _Panel({
    super.key,
    required this.heading,
    required this.body,
    required this.action,
    required this.onAction,
    this.caption,
    this.quiet,
    this.onQuiet,
  });

  final String heading;
  final String body;
  final String action;
  final VoidCallback onAction;
  final String? caption;
  final String? quiet;
  final VoidCallback? onQuiet;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: Palette.glassCard(radius: 28),
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            decoration: BoxDecoration(
              border: Border.all(color: Palette.hairline),
              borderRadius: BorderRadius.circular(22),
            ),
            padding: const EdgeInsets.fromLTRB(20, 24, 20, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  heading,
                  style: const TextStyle(
                    fontSize: 22,
                    height: 1.25,
                    fontWeight: FontWeight.w700,
                    color: Palette.text,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  body,
                  style: TextStyle(
                    fontSize: 16,
                    height: 1.45,
                    color: Palette.textDim(0.6),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          // WHITE fill, not crimson. Crimson is reserved for actions that
          // start or end a journey, and none of these do; white is also the
          // louder of the two on this ground. Same treatment as the "I'm
          // awake" button, for the same reason.
          GestureDetector(
            key: const Key('onboarding_action'),
            onTap: onAction,
            child: Container(
              decoration: BoxDecoration(
                color: Palette.text,
                borderRadius: BorderRadius.circular(30),
              ),
              padding: const EdgeInsets.symmetric(vertical: 20),
              child: Center(
                child: Text(
                  action,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: Palette.ground,
                  ),
                ),
              ),
            ),
          ),
          if (caption != null) ...[
            const SizedBox(height: 12),
            Center(
              child: Text(
                caption!,
                style: TextStyle(fontSize: 13, color: Palette.textDim(0.5)),
              ),
            ),
          ],
          if (quiet != null) ...[
            const SizedBox(height: 6),
            TextButton(
              key: const Key('onboarding_skip'),
              onPressed: onQuiet,
              child: Text(
                quiet!,
                style: TextStyle(fontSize: 15, color: Palette.textDim(0.55)),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
