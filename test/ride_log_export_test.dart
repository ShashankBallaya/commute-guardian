import 'dart:io';

import 'package:commute_guardian/services/ride_log_export.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:share_plus/share_plus.dart';

/// A VOLUNTEER'S RIDE LOG HAS TO BE ABLE TO LEAVE THEIR PHONE.
///
/// On Android 11 and later the logs live behind `Android/data`, which needs a
/// laptop, so before this existed a missed station on somebody else's ride was
/// unreportable except in words. These tests cover the half that can be wrong
/// silently: WHICH files go, in WHAT order, and what happens when there are
/// none or when the platform refuses the sheet.
void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('ride_log_export_test');
  });

  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  File writeLog(String name, {String body = 'FIX\n'}) {
    final file = File('${dir.path}${Platform.pathSeparator}$name')
      ..writeAsStringSync(body);
    return file;
  }

  String nameOf(File f) => f.path.split(Platform.pathSeparator).last;

  test('an empty directory yields no logs', () {
    expect(RideLogExport.recentLogs(dir), isEmpty);
  });

  test('a directory that does not exist yields no logs, and does not throw', () {
    dir.deleteSync();
    expect(RideLogExport.recentLogs(dir), isEmpty);
  });

  test('only ride logs go, never the database or the clip pack', () {
    writeLog('geofence_log_2026-08-21T09-00-00.000.txt');
    writeLog('journey_history.sqlite');
    writeLog('geofence_log_2026-08-21T09-00-00.000.txt.bak');
    writeLog('kalyan__approach.m4a');

    final logs = RideLogExport.recentLogs(dir).map(nameOf).toList();
    expect(logs, ['geofence_log_2026-08-21T09-00-00.000.txt']);
  });

  test('newest first, and by the stamp in the name rather than by mtime', () {
    // The ride that STARTED first can END last, and a log is appended to for
    // the whole ride. Sorting by mtime would call the older ride the newer one.
    final early = writeLog('geofence_log_2026-08-20T08-00-00.000.txt');
    writeLog('geofence_log_2026-08-21T08-00-00.000.txt');
    early.writeAsStringSync('later append\n', mode: FileMode.append);

    expect(RideLogExport.recentLogs(dir).map(nameOf), [
      'geofence_log_2026-08-21T08-00-00.000.txt',
      'geofence_log_2026-08-20T08-00-00.000.txt',
    ]);
  });

  test('at most three rides leave the phone', () {
    for (var day = 10; day < 20; day++) {
      writeLog('geofence_log_2026-08-${day}T08-00-00.000.txt');
    }

    final logs = RideLogExport.recentLogs(dir);
    expect(logs, hasLength(RideLogExport.keep));
    expect(logs.map(nameOf), [
      'geofence_log_2026-08-19T08-00-00.000.txt',
      'geofence_log_2026-08-18T08-00-00.000.txt',
      'geofence_log_2026-08-17T08-00-00.000.txt',
    ]);
  });

  test('with no rides yet it says so and never opens an empty sheet', () async {
    var opened = 0;
    final export = RideLogExport(
      shareSheet: (params) async => opened++,
    );

    expect(await export.share(from: dir), 'No ride logs yet. Take a ride first.');
    expect(opened, 0);
  });

  test('the sheet gets the files, a subject and a plain-English body', () async {
    writeLog('geofence_log_2026-08-21T08-00-00.000.txt');
    writeLog('geofence_log_2026-08-20T08-00-00.000.txt');

    ShareParams? sent;
    final export = RideLogExport(shareSheet: (params) async => sent = params);

    expect(await export.share(from: dir), isNull);
    expect(sent, isNotNull);
    expect(sent!.files!.map((f) => f.path.split(Platform.pathSeparator).last), [
      'geofence_log_2026-08-21T08-00-00.000.txt',
      'geofence_log_2026-08-20T08-00-00.000.txt',
    ]);
    expect(sent!.subject, 'Commute Guardian ride log');
    expect(sent!.text, 'My last 2 rides.');
  });

  test('one ride is not called "my last 1 rides"', () async {
    writeLog('geofence_log_2026-08-21T08-00-00.000.txt');
    ShareParams? sent;
    await RideLogExport(shareSheet: (p) async => sent = p).share(from: dir);
    expect(sent!.text, 'My last ride.');
  });

  test('it still looks where the ride actually writes', () {
    // THE COUPLING THAT WOULD FAIL SILENTLY. GeofenceChainService picks the
    // directory and the file name; this class has to make the same two choices
    // or the button opens on an empty folder and reports "no ride logs yet"
    // after a ride that wrote one. Neither side would look wrong on its own.
    final service = File(
      'lib/services/geofence_chain_service.dart',
    ).readAsStringSync().replaceAll('\r\n', '\n');
    final body = service
        .split('\n')
        .where((line) => !line.trimLeft().startsWith('//'))
        .join('\n');

    expect(
      body,
      contains('geofence_log_'),
      reason: 'The ride renamed its log. recentLogs still matches the old name.',
    );
    expect(
      body,
      contains('getExternalStorageDirectory'),
      reason: 'The ride moved its log. logDirectory still looks at the old place.',
    );
  });

  test('a share sheet that throws does not take the screen with it', () async {
    writeLog('geofence_log_2026-08-21T08-00-00.000.txt');
    final export = RideLogExport(
      shareSheet: (_) async => throw StateError('no activity found'),
    );

    final problem = await export.share(from: dir);
    expect(problem, contains('Could not open the share sheet'));
  });
}
