import 'package:commute_guardian/screens/ride_orchestration.dart';
import 'package:commute_guardian/screens/settings_screen.dart';
import 'package:commute_guardian/state/readiness_providers.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_permissions.dart';

/// Settings' readiness card, and what its dots are allowed to MEAN.
///
/// This card is the first thing on the Settings screen, and it is first
/// deliberately: OEM battery killers are this project's named top product risk,
/// and a rider whose app was killed mid-journey has no other way to find out.
///
/// UNTIL 12 AUG 2026 IT READ NOTHING. `ride_orchestration` passed
/// `readiness: const [...]`, three literals: location hardcoded green,
/// notifications hardcoded green, battery hardcoded amber with a fixed
/// sentence. It was labelled as scaffolding in a doc comment and never came
/// back to, so it showed green for location on a phone where the rider had
/// revoked it, and amber for battery on a phone that was already exempt. The
/// owner's 3T reported the GOOD battery state in every ride log while the card
/// told him it was restricted.
///
/// The mapping is a pure function so that every state below is reachable
/// without a device. None of them is reachable in a widget test: the platform
/// reads behind them do not exist under the test binding.
void main() {
  final gateway = FakePermissions();

  List<ReadinessItem> rows(TravelReadiness? readiness) =>
      RideOrchestration.readinessRows(
        readiness,
        onFixed: () {},
        gateway: gateway,
      );

  ReadinessItem row(List<ReadinessItem> items, String label) =>
      items.firstWhere((i) => i.label == label);

  const android = TravelReadiness(
    locationAlways: true,
    notifications: true,
    batteryExempt: true,
  );

  group('A ROW MAY NOT CLAIM WHAT IT HAS NOT READ', () {
    test('every row is CHECKING while the reads are in flight', () {
      final items = rows(null);

      expect(
        items.map((i) => i.state),
        everyElement(ReadinessState.checking),
        reason: 'green would tell a revoked rider they are ready, and amber '
            'would send a ready rider hunting for a setting',
      );
    });

    test('a checking row offers no Fix and no explanation', () {
      // Both are decided in the widget, which shows a detail and a Fix only for
      // a row KNOWN to be unmet. Here we assert the state that drives it, so a
      // future change to the widget cannot quietly start explaining a value it
      // does not have.
      expect(rows(null).first.state, ReadinessState.checking);
    });
  });

  group('WHAT GREEN AND AMBER MEAN', () {
    test('granted is green and refused is amber, for all three', () {
      final good = rows(android);
      expect(row(good, 'Location, always').state, ReadinessState.ok);
      expect(row(good, 'Notifications').state, ReadinessState.ok);
      expect(row(good, 'Battery use').state, ReadinessState.ok);

      final bad = rows(
        const TravelReadiness(
          locationAlways: false,
          notifications: false,
          batteryExempt: false,
        ),
      );
      expect(row(bad, 'Location, always').state, ReadinessState.needsAttention);
      expect(row(bad, 'Notifications').state, ReadinessState.needsAttention);
      expect(row(bad, 'Battery use').state, ReadinessState.needsAttention);
    });

    test('THE BATTERY ROW WENT GREEN, which the hardcoded card never could', () {
      // The exact case the owner hit on 12 Aug 2026: his 3T is exempt, every
      // ride log said `ignoringBatteryOptimizations=true`, and the card showed
      // amber anyway and sent him looking for a setting that was already right.
      expect(row(rows(android), 'Battery use').state, ReadinessState.ok);
    });

    test('every unmet row carries a Fix, because amber must be actionable', () {
      final bad = rows(
        const TravelReadiness(
          locationAlways: false,
          notifications: false,
          batteryExempt: false,
        ),
      );

      // The widget has supported a Fix button since it was written and nothing
      // ever passed one, so every amber row in the shipped app was a dead end:
      // it named a problem and offered no way to it.
      for (final item in bad) {
        expect(
          item.onFix,
          isNotNull,
          reason: '${item.label} says what is wrong and must say where to go',
        );
        expect(item.detail, isNotNull, reason: '${item.label} needs a why');
      }
    });
  });

  group('THE BATTERY ROW IS ANDROID ONLY', () {
    test('a null battery value drops the row rather than greying it', () {
      // iOS has no battery-optimisation concept, so there is nothing to report
      // and nothing a rider could fix. A row that can never go green is worse
      // than no row: it is the dead control from punchlist item 8 again.
      final items = rows(
        const TravelReadiness(
          locationAlways: true,
          notifications: true,
          batteryExempt: null,
        ),
      );

      expect(items.map((i) => i.label), ['Location, always', 'Notifications']);
    });

    test('building the rows never touches the platform', () {
      // A mapping that reached for a device while BUILDING would make the card
      // impossible to test and slow to draw. The gateway is for the Fix taps.
      rows(android);
      rows(null);
      expect(gateway.asked, isEmpty);
    });

    test('but it is PRESENT while still checking, so the card cannot jump', () {
      // Null-because-unknown and null-because-inapplicable are different
      // questions with the same Dart value, and only the second may remove a
      // row. Dropping it during the read would make the card lose a row and
      // then grow it back, on the screen a worried rider is staring at.
      expect(rows(null).length, 3);
    });
  });
}
