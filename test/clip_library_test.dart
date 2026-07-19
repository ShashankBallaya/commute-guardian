import 'package:commute_guardian/services/clip_library.dart';
import 'package:commute_guardian/services/ride_progress.dart';
import 'package:flutter_test/flutter_test.dart';

Announcement _a(AnnouncementKind kind, String stationId, String text) =>
    Announcement(stationId: stationId, kind: kind, text: text);

void main() {
  test('template-matching sentences map to their clip kinds', () {
    expect(
      announcementClipKind(
        announcement:
            _a(AnnouncementKind.approach, 'thane', 'Now approaching Thane.'),
        stationName: 'Thane',
      ),
      'approach',
    );
    // An ordinary station's arrival speaks the approach wording, so it uses
    // the approach clip.
    expect(
      announcementClipKind(
        announcement:
            _a(AnnouncementKind.arrival, 'kalwa', 'Now approaching Kalwa.'),
        stationName: 'Kalwa',
      ),
      'approach',
    );
    expect(
      announcementClipKind(
        announcement: _a(AnnouncementKind.arrival, 'nerul',
            'You have arrived at your destination, Nerul.'),
        stationName: 'Nerul',
      ),
      'destination',
    );
    expect(
      announcementClipKind(
        announcement:
            _a(AnnouncementKind.passed, 'rabale', 'You have passed Rabale.'),
        stationName: 'Rabale',
      ),
      'passed',
    );
    expect(
      announcementClipKind(
        announcement: _a(
            AnnouncementKind.overshoot,
            'shahad',
            'You have passed your stop. It is alright. Please alight here, '
            'at Shahad.'),
        stationName: 'Shahad',
      ),
      'overshoot',
    );
  });

  test('dynamic sentences never map to a clip (the ADR device-TTS floor)', () {
    // The Thane interchange script is composed at plan time; no closed-set
    // clip covers it, and splicing voices mid-ride is worse than TTS.
    expect(
      announcementClipKind(
        announcement: _a(
            AnnouncementKind.arrival,
            'thane',
            'You have reached Thane. Change here to the Trans Harbour line. '
            'Get off the train, go to platform number 9, 10, or 10 A, then '
            'board the Trans Harbour train to continue to your destination.'),
        stationName: 'Thane',
      ),
      isNull,
    );
    // A sentence that names a DIFFERENT station than the announcement's own
    // must not match either: the byte-identical rule is per station.
    expect(
      announcementClipKind(
        announcement:
            _a(AnnouncementKind.approach, 'thane', 'Now approaching Kalwa.'),
        stationName: 'Thane',
      ),
      isNull,
    );
  });
}
