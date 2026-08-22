import 'dart:io';
import 'dart:ui' show Rect;

import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

/// GETS A RIDE LOG OFF A PHONE THAT IS NOT IN THIS ROOM.
///
/// Every ride writes one `geofence_log_<stamp>.txt` next to the app's own
/// files. On the owner's phones that is fine: they come off over `adb pull` or
/// out of Files on the iPhone. A VOLUNTEER CANNOT DO EITHER. On Android 11 and
/// later `Android/data` needs a laptop, which is the exact wall that made the
/// clip pack undeliverable until 19 Aug 2026.
///
/// So without this, a missed station on somebody else's ride comes back as one
/// sentence of prose. Sentry and Aptabase cannot fill the gap: a phone killed
/// in a pocket reports nothing, and the 21 Aug ride ran 95 percent offline.
///
/// The share sheet is the whole answer. It is the one file-moving surface every
/// Android and iOS user already knows, and it needs no storage permission,
/// because the app hands the file out rather than the other side coming in.
class RideLogExport {
  const RideLogExport({ShareSheet? shareSheet})
    : _shareSheet = shareSheet ?? _systemShareSheet;

  final ShareSheet _shareSheet;

  /// How many logs go in one share. The last ride is the one being reported;
  /// the two before it cost nothing and cover "it also did it on Tuesday".
  /// Everything older is left on the phone rather than mailed to us: these
  /// files name every station the rider passed, which is not ours to hoover up.
  static const keep = 3;

  /// THE SAME CHOICE `GeofenceChainService` MAKES, and it has to stay that way
  /// or this button shares an empty directory. Android external files dir, so
  /// `adb pull` still works for the phones in this room; app documents
  /// elsewhere, which on iOS is what the Files app shows.
  static Future<Directory> logDirectory() async {
    final external = Platform.isAndroid
        ? await getExternalStorageDirectory()
        : null;
    return external ?? await getApplicationDocumentsDirectory();
  }

  /// Newest first, at most [keep].
  ///
  /// Pure and synchronous on purpose: it is the half of this class that can be
  /// tested at a desk, and the sort order is the half that can be wrong without
  /// looking wrong. Sorted by the NAME, which carries an ISO 8601 stamp and so
  /// sorts chronologically as text, and not by mtime: a log is appended to for
  /// the whole ride, so mtime says when a ride ENDED, and a ride that started
  /// first can end last.
  static List<File> recentLogs(Directory dir) {
    if (!dir.existsSync()) return const [];
    final logs =
        dir
            .listSync()
            .whereType<File>()
            .where((f) => _logName.hasMatch(_basename(f.path)))
            .toList()
          ..sort((a, b) => _basename(b.path).compareTo(_basename(a.path)));
    return logs.take(keep).toList();
  }

  static final _logName = RegExp(r'^geofence_log_.+\.txt$');

  static String _basename(String path) =>
      path.split(Platform.pathSeparator).last.split('/').last;

  /// Opens the share sheet on the recent logs. Returns what to tell the rider,
  /// or null when the sheet opened and there is nothing to say.
  ///
  /// [origin] is the iPad popover anchor. Passing it wrong is not a cosmetic
  /// bug there: the sheet refuses to open at all.
  ///
  /// [from] exists for the tests. path_provider has no answer in a widget test
  /// host, so the default would throw before reaching anything worth checking.
  Future<String?> share({Rect? origin, Directory? from}) async {
    final logs = recentLogs(from ?? await logDirectory());
    if (logs.isEmpty) {
      return 'No ride logs yet. Take a ride first.';
    }

    try {
      await _shareSheet(
        ShareParams(
          files: [for (final file in logs) XFile(file.path)],
          // Named so an inbox full of them can be told apart without opening
          // one. The sha is not in here because the log itself carries the
          // build in its first lines.
          subject: 'Commute Guardian ride log',
          text: logs.length == 1
              ? 'My last ride.'
              : 'My last ${logs.length} rides.',
          sharePositionOrigin: origin,
        ),
      );
    } catch (error) {
      // A share sheet that throws must not take the Settings screen with it.
      // Some Android skins have no target at all for text/plain files.
      return 'Could not open the share sheet: $error';
    }
    return null;
  }

  static Future<void> _systemShareSheet(ShareParams params) =>
      SharePlus.instance.share(params);
}

/// Seam for the tests. The real one opens the platform share sheet, which no
/// widget test can drive.
typedef ShareSheet = Future<void> Function(ShareParams params);
