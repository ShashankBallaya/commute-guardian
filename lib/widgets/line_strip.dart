import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../data/station_repository.dart';
import '../theme/palette.dart';
import '../theme/type_scale.dart';

/// Five stations of the rider's own line, with the rider in the middle.
///
/// TRIAL, added 25 Aug 2026 to answer a question with the phone rather than an
/// argument: does a small live strip make Screen 1's empty top worth having, or
/// does the screen need a commissioned network map?
///
/// WHY FIVE STATIONS AND NOT THE NETWORK. The owner asked for a Mumbai line map
/// in that space, and a session spent generating one settled that an algorithm
/// cannot produce a diagram anybody wants: 127 stations across 124 km leaves
/// about 21 px a stop, no label fits, and the south Mumbai cluster needs
/// deliberate distortion that only a designer supplies. Then he described what
/// he actually wanted, which turned out to be much smaller: opening the app and
/// seeing where you are, two stations either side. That is one ordered list out
/// of the station data. Nothing to draw, nothing to hand-author, nothing to
/// maintain when `build_stations.py` regenerates, and at five stations the
/// NAMES FIT, so the thing stops being a picture and starts being information.
///
/// NO DIRECTION, DECIDED. On Screen 1 the rider has not picked a destination,
/// so the app does not know which way they face: at Dadar, "two ahead" is
/// Matunga and Sion towards Kalyan or Parel and Currey Road towards CSMT, same
/// station, opposite answers. So the strip shows the line AS IT LIES and claims
/// no heading. It is orientation, not navigation. Guessing would be guessing at
/// the moment the app knows least, and a strip pointing the wrong way at 6 AM
/// is worse than one pointing nowhere.
///
/// NOT INTERACTIVE. Nothing here starts a ride. The cards below do that, and a
/// 10 px dot is a worse way to pick a destination than a list with a search box.
class LineStrip extends StatefulWidget {
  const LineStrip({super.key, required this.window, this.located = true});

  /// The stations to draw, and which of them the rider is at.
  final LineWindow window;

  /// False while the fix is still landing, or when location is unavailable.
  ///
  /// The strip STAYS DRAWN and simply claims no position: the dot is the only
  /// thing that asserts where the rider is, and an assertion without a fix
  /// behind it is the one thing this screen must not make. Hiding the strip
  /// instead would mean a block of the screen appearing a few seconds after
  /// every cold launch, which moves the cards under a reaching thumb.
  /// [StatusChip] owns saying so in words.
  final bool located;

  /// HORIZONTAL WITH ALTERNATING LABELS, at the owner's call, 25 Aug 2026,
  /// after seeing the vertical one on the 3T.
  ///
  /// Horizontal costs height: about half the vertical strip's, so more of
  /// Screen 1's empty top stays empty. It also cuts each name to about 75 dp of
  /// its own, which is where ALTERNATING earns its place: a name above the rail
  /// cannot collide with the two beside it below the rail, so each one may run
  /// nearly two slots wide. That is the difference between "Seawoods Darave"
  /// reading and ellipsizing. The median station name is 8 characters and only
  /// 14 of 127 run past 12.
  static const height = 140.0;

  /// The rail's own line, measured from the top of [height]. Labels hang above
  /// and below it.
  static const railY = 66.0;

  /// Even index below the rail, odd above.
  ///
  /// Even rather than odd so the RIDER is always below: the window puts them at
  /// index 2, and at a terminus it slides them to 0 or 4, all even. Their name
  /// therefore never jumps sides as they travel, which a strip that alternates
  /// by parity of position would do at every station.
  static bool isBelow(int index) => index.isEven;

  @override
  State<LineStrip> createState() => _LineStripState();
}

class _LineStripState extends State<LineStrip>
    with SingleTickerProviderStateMixin {
  /// THE GLOW BREATHES, at the owner's call.
  ///
  /// I argued against a permanent pulse: Screen 1 is opened several times a
  /// day, and the animation framework's own rule is to reduce or remove motion
  /// at that frequency. His answer is that this is the one live thing on the
  /// screen and it should look alive, and on a pre-ride screen the rider is
  /// looking AT the screen rather than through it. Both are true, so the
  /// compromise is in the numbers: slow (1.8 s), shallow, only the HALO moves,
  /// and it stops dead under reduced motion.
  late final AnimationController _glow = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1800),
  );

  @override
  void initState() {
    super.initState();
    _glow.repeat(reverse: true);
  }

  @override
  void dispose() {
    _glow.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final stations = widget.window.stationNames;
    if (stations.length < 2) return const SizedBox.shrink();

    final current = widget.window.currentIndex;
    final reduced = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (reduced && _glow.isAnimating) {
      _glow.stop();
    } else if (!reduced && !_glow.isAnimating) {
      _glow.repeat(reverse: true);
    }

    return SizedBox(
      height: LineStrip.height,
      // THE WINDOW CROSSFADES WHEN THE RIDER MOVES A STATION, 27 Aug 2026.
      //
      // Before this, five labels and the dot swapped between one frame and the
      // next. The swap is RARE (a station is minutes apart, not seconds) and
      // it is a real change of information, which is the case the animation
      // rule actually allows: this is not decoration on a repeated action, it
      // is the one moment the strip has something new to say.
      //
      // 200 ms, and the band is the argument. Under about 150 ms a crossfade
      // reads as the same instant swap with a smear on it; over about 300 ms
      // the two sets of names are legibly on screen together and it reads as a
      // glitch rather than a change. 200 sits in the middle and is the same
      // number the rest of this app uses for a state change.
      //
      // KEYED ON WHAT IS DRAWN, not on the rider's station id. `located`
      // belongs in the key because losing a fix redraws the dot, and the names
      // belong in it because a through-service splice can change the whole
      // window without the middle station moving.
      child: AnimatedSwitcher(
        duration: reduced ? Duration.zero : const Duration(milliseconds: 200),
        // The outgoing window fades on the same curve as the incoming one, so
        // neither set of names is ever the brighter of the two.
        switchInCurve: Curves.easeInOut,
        switchOutCurve: Curves.easeInOut,
        child: KeyedSubtree(
          key: ValueKey(
            '${stations.join('|')}#$current'
            '#${widget.located}'
            '#${widget.window.continuesBefore}${widget.window.continuesAfter}',
          ),
          child: _window(stations, current, reduced),
        ),
      ),
    );
  }

  /// One window's worth of strip: rail, halo, dots and labels.
  ///
  /// Split out of [build] so [AnimatedSwitcher] has a whole subtree to swap.
  Widget _window(List<String> stations, int current, bool reduced) {
    return
    // LayoutBuilder is safe here despite FillOrScroll's IntrinsicHeight: the
    // SizedBox above answers a height intrinsic from its own fixed value and
    // never asks its child, so the builder is not queried for one.
    LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final slot = width / stations.length;
        // Nearly two slots, because the neighbours are on the other side of
        // the rail and cannot be run into. Held just under 2 so two labels on
        // the SAME side, which are two slots apart, still keep a gap.
        final labelWidth = slot * 1.9;

        return Stack(
          clipBehavior: Clip.none,
          children: [
            // THE HALO IS ITS OWN LAYER, UNDER THE RAIL.
            //
            // It is the only thing on this widget that moves, and it is about
            // 26 px across. Painting it inside the rail's own painter meant
            // the rail, five dots and the gradient were all rebuilt sixty
            // times a second for it, and without a boundary that repaint
            // could reach the rest of Screen 1. Split and bounded, the moving
            // part costs one small layer and the static part is painted once.
            Positioned.fill(
              child: RepaintBoundary(
                child: AnimatedBuilder(
                  animation: _glow,
                  builder: (context, _) => CustomPaint(
                    painter: _GlowPainter(
                      stops: stations.length,
                      current: current,
                      located: widget.located,
                      railY: LineStrip.railY,
                      breath: reduced ? 0.5 : _glow.value,
                    ),
                  ),
                ),
              ),
            ),
            Positioned.fill(
              child: CustomPaint(
                painter: _RailPainter(
                  stops: stations.length,
                  current: current,
                  located: widget.located,
                  railY: LineStrip.railY,
                  continuesBefore: widget.window.continuesBefore,
                  continuesAfter: widget.window.continuesAfter,
                ),
              ),
            ),
            for (final (i, name) in stations.indexed)
              _positionedLabel(
                index: i,
                name: name,
                current: current,
                slot: slot,
                width: width,
                labelWidth: labelWidth,
              ),
          ],
        );
      },
    );
  }

  Widget _positionedLabel({
    required int index,
    required String name,
    required int current,
    required double slot,
    required double width,
    required double labelWidth,
  }) {
    final centre = slot / 2 + slot * index;
    // Clamped so the first and last names stay inside the screen instead of
    // running under the padding. They shift off their dot rather than clip.
    var left = centre - labelWidth / 2;
    if (left < 0) left = 0;
    if (left + labelWidth > width) left = width - labelWidth;

    final below = LineStrip.isBelow(index);
    final label = _Label(
      name: name,
      // OPACITY FALLS OFF WITH DISTANCE, NOT WITH DIRECTION. He asked for the
      // station behind to be fainter and the one ahead a little stronger. On
      // Screen 1 there is no behind or ahead: no destination is picked, so the
      // app does not know which way he faces. Distance from the rider gives the
      // same shape of emphasis and claims nothing the app cannot know.
      distance: (index - current).abs(),
      isCurrent: index == current && widget.located,
      alignBottom: !below,
    );

    return below
        ? Positioned(
            left: left,
            width: labelWidth,
            top: LineStrip.railY + 14,
            bottom: 0,
            child: label,
          )
        : Positioned(
            left: left,
            width: labelWidth,
            top: 0,
            height: LineStrip.railY - 14,
            child: label,
          );
  }
}

class _Label extends StatelessWidget {
  const _Label({
    required this.name,
    required this.distance,
    required this.isCurrent,
    required this.alignBottom,
  });

  final String name;
  final int distance;
  final bool isCurrent;

  /// Labels above the rail sit ON it, so they grow upward; labels below grow
  /// downward. Either way the gap to the rail stays the same, which is what
  /// keeps a two-line name from looking further away than a one-line one.
  final bool alignBottom;

  @override
  Widget build(BuildContext context) {
    final opacity = switch (distance) {
      0 => 1.0,
      1 => 0.52,
      _ => 0.26,
    };
    return Align(
      alignment: alignBottom ? Alignment.bottomCenter : Alignment.topCenter,
      child: Text(
        name,
        textAlign: TextAlign.center,
        // The rider's own station gets two lines because it is the one name
        // worth reading in full. The context stations get one and ellipsize.
        maxLines: isCurrent ? 2 : 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          // The rider's own station is the anchor of the whole strip, so it
          // carries both the size and the weight. Everything else on the rail
          // is context and stays at caption, which is what makes the eye land
          // here first. Stops short of `display`: this is orientation, and the
          // white CTA below is still the only thing on Screen 1 that acts.
          fontSize: isCurrent ? TypeScale.title : TypeScale.caption,
          fontWeight: isCurrent ? FontWeight.w600 : FontWeight.w400,
          height: 1.15,
          color: isCurrent ? Palette.text : Palette.textDim(opacity),
        ),
      ),
    );
  }
}

/// The locked motif on its side: dim dots on a hairline, one live green dot
/// with a halo that breathes.
///
/// Painted rather than composed because the rail is one continuous line behind
/// the dots, and a Row of Containers cannot draw that without seams.
class _RailPainter extends CustomPainter {
  const _RailPainter({
    required this.stops,
    required this.current,
    required this.located,
    required this.railY,
    required this.continuesBefore,
    required this.continuesAfter,
  });

  final int stops;
  final int current;
  final bool located;
  final double railY;
  final bool continuesBefore;
  final bool continuesAfter;

  @override
  void paint(Canvas canvas, Size size) {
    final slot = size.width / stops;
    final firstX = slot / 2;
    final lastX = size.width - slot / 2;

    // ONE UNBROKEN STROKE, FADING WHERE THE LINE CARRIES ON.
    //
    // It used to run dot to dot and stop, on the reasoning that drawing to the
    // edges would promise stations the strip is not showing. A fade makes that
    // promise honestly: the line does go on, and this is a window onto it. What
    // a fade must NOT do is invent line at a real terminus, so the two ends are
    // drawn independently: transparent at the edge where the line continues,
    // full strength right up to the last dot where it does not.
    final rail = Palette.textDim(0.16);
    final left = continuesBefore ? 0.0 : firstX;
    final right = continuesAfter ? size.width : lastX;
    canvas.drawLine(
      Offset(left, railY),
      Offset(right, railY),
      Paint()
        ..strokeWidth = 1.5
        ..strokeCap = StrokeCap.round
        ..shader = ui.Gradient.linear(
          Offset(left, railY),
          Offset(right, railY),
          [
            continuesBefore ? rail.withValues(alpha: 0) : rail,
            rail,
            rail,
            continuesAfter ? rail.withValues(alpha: 0) : rail,
          ],
          [
            0,
            // The fade is spent by the time it reaches the first dot, so the
            // stations themselves always sit on a rail at full strength.
            continuesBefore ? (firstX - left) / (right - left) : 0,
            continuesAfter ? (lastX - left) / (right - left) : 1,
            1,
          ],
        ),
    );

    for (var i = 0; i < stops; i++) {
      final x = firstX + slot * i;
      if (i == current && located) {
        // The dot itself never moves. A live dot that changes size makes the
        // rail look like it is breathing too, and the rail is not alive.
        canvas.drawCircle(
          Offset(x, railY),
          6,
          Paint()..color = Palette.dotGreen,
        );
      } else {
        // Hollow, so a dim dot never reads as a second live one.
        canvas.drawCircle(
          Offset(x, railY),
          3.5,
          Paint()..color = Palette.ground,
        );
        canvas.drawCircle(
          Offset(x, railY),
          3.5,
          Paint()
            ..color = Palette.textDim(0.28)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_RailPainter old) =>
      old.stops != stops ||
      old.current != current ||
      old.located != located ||
      old.continuesBefore != continuesBefore ||
      old.continuesAfter != continuesAfter;
}

/// The five stations to draw and where the rider sits among them.
///
/// A value rather than a widget's own lookup so the rule that picks them can be
/// tested without pumping a screen, which is the house pattern.
class LineWindow {
  const LineWindow({
    required this.stationNames,
    required this.currentIndex,
    this.continuesBefore = false,
    this.continuesAfter = false,
  });

  final List<String> stationNames;

  /// Index of the rider's station within [stationNames], which is the MIDDLE
  /// one except at the ends of a line, where the window slides rather than
  /// padding itself with blanks. Standing at CSMT there is nothing behind, so
  /// the rider sits at the top and sees four ahead.
  final int currentIndex;

  /// Whether the line carries on past the first station shown, and past the
  /// last. FALSE AT A REAL TERMINUS, and the difference is drawn: the rail
  /// fades out where there is more line, and stops cleanly where there is not.
  /// Fading at CSMT would promise a stretch of Mumbai that does not exist.
  final bool continuesBefore;
  final bool continuesAfter;

  /// How many stations the strip shows, and it is an odd number so the rider
  /// can sit in the middle.
  static const size = 5;

  /// The rider's line EXTENDED ACROSS ITS THROUGH SERVICES.
  ///
  /// Found on the 3T, 25 Aug 2026, and it is exactly the class of bug a green
  /// test suite cannot see. Standing at Shahad the strip drew Kalyan, Shahad,
  /// Ambivli, Titwala, Khadavli, with the rider second from the top as though
  /// nothing existed behind him. Shahad is on the Kasara branch, whose station
  /// list BEGINS at Kalyan, so the window slid to the start of the list. But a
  /// Kasara train runs through Kalyan and carries on down the trunk to CSMT
  /// while the rider sits still: there is most of Mumbai behind Shahad. The
  /// same `throughServices` the planner uses says so.
  ///
  /// A BRANCH SPLICES ONTO THE TRUNK; THE TRUNK SPLICES ONTO NEITHER. Kalyan
  /// carries two through services, Kasara and Karjat, so a rider on the trunk
  /// has a Y ahead of them and no single strip can draw both. From a branch
  /// there is exactly one way home and the splice is unambiguous. So an
  /// endpoint shared by more than one partner is left alone, which is a real
  /// limit and the honest one: on the trunk the strip stops at Kalyan rather
  /// than guessing which branch the rider wants.
  static (List<String>, bool, bool) _corridor(
    StationRepository repo,
    String lineId,
  ) {
    var ids = [...repo.linesById[lineId]!.stationIds];
    // Set when a corridor stops for OUR reasons rather than the network's: the
    // line really carries on, we just cannot draw which way. That difference is
    // visible, because the rail fades where there is more line and stops clean
    // at a terminus, and a hard stop at Kalyan would call it the end of the
    // Central main.
    var openStart = false;
    var openEnd = false;

    for (final pair in repo.throughServices) {
      if (pair.length != 2 || !pair.contains(lineId)) continue;
      final otherId = pair[0] == lineId ? pair[1] : pair[0];
      final other = repo.linesById[otherId];
      if (other == null) continue;

      // The station the two lines meet at has to be an END of ours, or this is
      // not a through run, it is a crossing.
      final shared = other.stationIds.toSet().intersection(ids.toSet());
      if (shared.length != 1) continue;
      final joint = shared.first;

      // Ambiguous junction: more than one partner meets us here (Kalyan, from
      // the trunk). Draw nothing beyond it rather than pick a branch.
      final partnersHere = [
        for (final p in repo.throughServices)
          if (p.length == 2 && p.contains(lineId))
            if (repo.linesById[p[0] == lineId ? p[1] : p[0]]?.stationIds
                    .contains(joint) ??
                false)
              p,
      ];
      if (partnersHere.length > 1) {
        if (ids.first == joint) {
          openStart = true;
        } else if (ids.last == joint) {
          openEnd = true;
        }
        continue;
      }

      final otherIds = [...other.stationIds];
      if (ids.first == joint) {
        // They run in behind us: put them ahead of our list, ending at the
        // joint, and drop the duplicate.
        if (otherIds.last != joint) {
          final reversed = otherIds.reversed.toList();
          if (reversed.last == joint) {
            otherIds
              ..clear()
              ..addAll(reversed);
          } else {
            continue;
          }
        }
        ids = [...otherIds.sublist(0, otherIds.length - 1), ...ids];
      } else if (ids.last == joint) {
        if (otherIds.first != joint) {
          final reversed = otherIds.reversed.toList();
          if (reversed.first == joint) {
            otherIds
              ..clear()
              ..addAll(reversed);
          } else {
            continue;
          }
        }
        ids = [...ids, ...otherIds.skip(1)];
      }
    }

    return (ids, openStart, openEnd);
  }

  /// The window around [stationId], or null when there is nothing to draw.
  ///
  /// WHICH LINE, at a station that has more than one. Kurla is Central and
  /// Harbour; CSMT is Central and Harbour; Thane is Central and Trans-Harbour.
  /// The strip has to pick one, and picking wrong is cheap here in a way it
  /// never is on the ride path: nothing is announced, nothing is planned, and
  /// the rider's own station is right in the middle either way. So the rule is
  /// the simplest one that cannot wobble between launches: the lines are sorted
  /// by id and the first is used. Deterministic beats clever, and if this ever
  /// deserves better the answer is the rider's own history, not a heuristic.
  static LineWindow? around(StationRepository? repo, String? stationId) {
    if (repo == null || stationId == null) return null;

    final lineIds = [
      for (final line in repo.linesById.values)
        if (line.stationIds.contains(stationId)) line.id,
    ]..sort();
    if (lineIds.isEmpty) return null;

    final (ids, openStart, openEnd) = _corridor(repo, lineIds.first);
    final at = ids.indexOf(stationId);
    if (at < 0) return null;

    // A line shorter than the window shows all of itself rather than padding,
    // and by definition nothing continues past either end of it.
    if (ids.length <= size) {
      return LineWindow(
        stationNames: [for (final id in ids) repo.stationsById[id]!.name],
        currentIndex: at,
        continuesBefore: openStart,
        continuesAfter: openEnd,
      );
    }

    // Slide, do not pad: at a terminus the rider sits at the end of a full
    // window instead of looking at two empty rows.
    var start = at - size ~/ 2;
    if (start < 0) start = 0;
    if (start + size > ids.length) start = ids.length - size;

    return LineWindow(
      stationNames: [
        for (final id in ids.sublist(start, start + size))
          repo.stationsById[id]!.name,
      ],
      currentIndex: at - start,
      continuesBefore: start > 0 || openStart,
      continuesAfter: start + size < ids.length || openEnd,
    );
  }
}

/// The live dot's halo, and nothing else.
///
/// Separate from [_RailPainter] so the sixty-frames-a-second repaint covers one
/// small circle instead of the whole rail. Painted UNDER the rail layer, which
/// is why the hairline reads across it: a halo drawn over the line would make
/// the rail look broken at the one station that matters.
class _GlowPainter extends CustomPainter {
  const _GlowPainter({
    required this.stops,
    required this.current,
    required this.located,
    required this.railY,
    required this.breath,
  });

  final int stops;
  final int current;
  final bool located;
  final double railY;

  /// 0 to 1, the halo's position in its own slow travel.
  final double breath;

  @override
  void paint(Canvas canvas, Size size) {
    if (!located) return;
    final slot = size.width / stops;
    final x = slot / 2 + slot * current;
    // easeInOut, because the ends of a linear travel are where a pulse looks
    // like it is hesitating rather than breathing.
    final t = Curves.easeInOut.transform(breath);
    canvas.drawCircle(
      Offset(x, railY),
      9.5 + 3.5 * t,
      Paint()..color = Palette.greenSoft.withValues(alpha: 0.32 - 0.14 * t),
    );
  }

  @override
  bool shouldRepaint(_GlowPainter old) =>
      old.stops != stops ||
      old.current != current ||
      old.located != located ||
      old.breath != breath;
}
