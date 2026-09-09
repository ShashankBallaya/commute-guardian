import 'package:commute_guardian/foreground/geofence_task_handler.dart';
import 'package:flutter_test/flutter_test.dart';

/// The chosen corridor crossing the isolate boundary.
///
/// ONE CODEC, AND IT USED TO BE THREE. The chain is joined by the UI, split by
/// the UI's own reader, and split AGAIN inside the service isolate, which is
/// how the two halves quietly disagreed: on ',,' one answered null and the
/// other answered an empty list. Nothing rode on that difference yet, which is
/// the only reason it was harmless. A codec whose two ends are written twice
/// is a codec that will disagree about something that matters later.
void main() {
  group('the stored route chain', () {
    test('goes out and comes back the same ride', () {
      const chain = ['ghansoli', 'thane', 'csmt'];

      expect(routeChainFromStore(routeChainToStore(chain)), chain);
    });

    test('NOTHING CHOSEN IS NULL, however the store spells it', () {
      // Three spellings of "no chosen route", and they must not be three
      // answers. Absent is a store written before C7c. Empty is what a start
      // writes to clear the PREVIOUS ride's chain. Separators alone is the
      // shape the two hand-written splitters disagreed about.
      expect(routeChainFromStore(null), isNull);
      expect(routeChainFromStore(''), isNull);
      expect(routeChainFromStore(',,'), isNull);
    });

    test('an unchosen route is written, not left behind', () {
      // A start with no chosen route still WRITES. Leaving the key alone would
      // hand this ride the last ride's corridor, which is the trap the
      // progress keys learned on 18 Aug 2026.
      expect(routeChainToStore(null), '');
    });
  });
}
