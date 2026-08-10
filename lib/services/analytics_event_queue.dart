import 'package:aptabase_flutter/storage_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// One Aptabase event queue per isolate, which is what stops a ride being
/// counted twice.
///
/// THE BUG THIS EXISTS FOR, found in the 9 Aug 2026 export. Two of five rides
/// were double-counted, with identical timestamps, and the cause is the package
/// meeting our own design:
///
///   - `aptabase_flutter` queues every event in SharedPreferences under an
///     `aptabase_` prefix and flushes it on a 30 second timer.
///   - `StorageManagerSharedPrefs.init()` copies every queued event it finds
///     into an in-memory map ONCE, at startup, and sends from that snapshot.
///   - we start the SDK in BOTH isolates, for reasons that still hold: the UI
///     records the app open, and the ride events must come from the service
///     because the UI can die mid-ride (30 Jul swipe bench).
///
/// So an isolate starting while the other had events waiting ADOPTED them and
/// sent them again. The timestamp is stamped when an event is queued, not when
/// it is sent, which is why the duplicates are identical rather than seconds
/// apart, and the local key never leaves the device, so the far end has nothing
/// to de-duplicate on. On 9 Aug the app was force-stopped and reopened mid-ride,
/// which is exactly a UI isolate starting on top of a service isolate's queue.
///
/// The fix is a namespace, not a lock. A cross-isolate lock would be the wrong
/// tool twice over: there is nothing to coordinate (neither isolate wants the
/// other's events) and a lock on the ride path is a risk taken for the benefit
/// of counting.
///
/// Events left under the package's own `aptabase_` keys by an earlier build are
/// now ignored rather than adopted. That is deliberate: those are 9 Aug events
/// at the latest, and re-sending a stale ride is the failure this class exists
/// to prevent.
class IsolateEventQueue extends StorageManager {
  IsolateEventQueue(this.scope);

  /// Names the queue, and must differ between isolates. See [AnalyticsIsolate],
  /// which is an enum so that a typo cannot quietly open a third queue.
  final String scope;

  /// Deliberately NOT `aptabase_`: the package scans its own prefix, and an
  /// overlap would put us back where we started.
  String get _prefix => 'cg_aptabase_${scope}_';

  /// Mirrors the package's own design: the queue is served from memory and
  /// SharedPreferences is the copy that survives the process.
  final _events = <String, String>{};

  @override
  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    for (final stored in prefs.getKeys()) {
      if (!stored.startsWith(_prefix)) continue;
      final value = prefs.get(stored);
      // Events queued by an isolate that died before its timer fired. THIS is
      // the recovery that matters: a service isolate the OS killed mid-ride
      // still gets its ride counted by the next one.
      if (value is String) _events[stored.substring(_prefix.length)] = value;
    }
    return super.init();
  }

  @override
  Future<void> addEvent(String key, String event) async {
    _events[key] = event;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('$_prefix$key', event);
  }

  @override
  Future<void> deleteEvents(Set<String> keys) async {
    _events.removeWhere((key, _) => keys.contains(key));
    final prefs = await SharedPreferences.getInstance();
    for (final key in keys) {
      await prefs.remove('$_prefix$key');
    }
  }

  /// The package's keys go in and come back out unchanged. The prefix belongs to
  /// storage and never to the caller, which is what keeps this a drop-in.
  @override
  Future<Iterable<MapEntry<String, String>>> getItems(int length) async =>
      _events.entries.take(length);
}
