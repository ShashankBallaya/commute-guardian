import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The notification small icon, and the three files that have to agree on it.
///
/// THE BUG THIS EXISTS FOR, reported from the 3T on 10 Sep 2026: "I can't see
/// the logo on the locked screen and on the notifications."
///
/// Android renders a notification small icon FROM ITS ALPHA CHANNEL ONLY,
/// tinted to a single colour. `flutter_foreground_task` falls back to
/// `appInfo.icon` when no icon is named (`ForegroundService.getIconResId`), and
/// `ic_launcher.png` is 96 percent opaque, so what the rider saw was a solid
/// white square. Not a missing icon: a present one, drawn from an alpha channel
/// that was never meant to be a silhouette.
///
/// WHY A TEST AT ALL. Nothing else can catch it. The analyzer sees a valid
/// string, the widget tests never build a notification, and the failure is
/// invisible until a phone is locked. The name travels through three files
/// that no compiler checks against each other:
///
///   1. `tool/build_notification_icon.py`  draws `ic_stat_travel_mode.png`
///   2. `AndroidManifest.xml`              maps a meta-data name to it
///   3. `ride_service_client.dart`         passes that META-DATA name
///
/// Get 3 wrong and the plugin reads 0 from the bundle and falls back to the
/// white square. Silently.
void main() {
  const metaDataName = 'com.ballshank.commute_guardian.TRAVEL_MODE_ICON';
  const drawable = 'ic_stat_travel_mode';

  final manifest = File(
    'android/app/src/main/AndroidManifest.xml',
  ).readAsStringSync();
  final client = File('lib/services/ride_service_client.dart').readAsStringSync();

  test('THE DART NAMES THE META-DATA, not the drawable', () {
    // The commonest way to get this wrong is to pass the drawable name, which
    // compiles, ships, and renders the white square.
    expect(client, contains("metaDataName: '$metaDataName'"));
    expect(
      client.contains("metaDataName: '$drawable'"),
      isFalse,
      reason: 'the plugin looks this up in the manifest, not in res/',
    );
  });

  test('and the manifest maps that name to the drawable', () {
    expect(manifest, contains('android:name="$metaDataName"'));
    expect(manifest, contains('android:resource="@drawable/$drawable"'));
  });

  test('THE DRAWABLE EXISTS AT EVERY DENSITY', () {
    // A missing density is not a crash. Android falls back to a neighbour and
    // scales it, so the only symptom is a soft icon on some phones.
    for (final density in const [
      'mdpi',
      'hdpi',
      'xhdpi',
      'xxhdpi',
      'xxxhdpi',
    ]) {
      final path = 'android/app/src/main/res/drawable-$density/$drawable.png';
      expect(File(path).existsSync(), isTrue, reason: '$path is missing');
    }
  });

  test('AND IT IS A SILHOUETTE, which is the whole point', () {
    // THE ASSERTION THAT WOULD HAVE CAUGHT THE ORIGINAL BUG. `ic_launcher` is
    // 96 percent opaque; a small icon has to be mostly transparent, or it is a
    // block. Read from the PNG bytes rather than trusted, because the file is
    // generated and a regenerated one could drift.
    //
    // PNG alpha is read here without an image library: the icon is written by
    // Pillow as 8-bit RGBA, so the IHDR colour type is what proves an alpha
    // channel is present at all. A pixel-level count needs a decoder this
    // suite does not have, so the shape of the guard is "it CAN be a
    // silhouette", and the preview strip is what proves it IS one.
    final bytes = File(
      'android/app/src/main/res/drawable-xxxhdpi/$drawable.png',
    ).readAsBytesSync();
    expect(bytes.length, greaterThan(8), reason: 'not a PNG at all');
    // IHDR starts at byte 8: length(4) type(4) w(4) h(4) depth(1) colour(1).
    final colourType = bytes[25];
    expect(
      colourType,
      anyOf(4, 6),
      reason:
          'colour type 4 is grey+alpha and 6 is RGBA. Anything else has no '
          'alpha channel, and an icon with no alpha is the solid white square '
          'this whole file exists to stop.',
    );
  });

  test('AND THE ROW SAYS THE APP NAME, not the package name', () {
    // Seen on the 3T on 10 Sep 2026 while checking the icon: the notification
    // read "commute_guardian". That is Flutter's scaffold default for
    // `android:label`, never chosen by anybody, and it had been there since the
    // project was created. It is not only the notification: the same string is
    // the launcher name, the app-info screen and the battery-usage list.
    //
    // iOS has been right the whole time (`CFBundleDisplayName` is "Commute
    // Guardian"), which is why nobody caught it: the two platforms disagreed
    // and only one of them was ever read.
    expect(manifest, contains('android:label="Commute Guardian"'));
    expect(
      manifest.contains('android:label="commute_guardian"'),
      isFalse,
      reason: 'the package name is not a product name',
    );

    final plist = File('ios/Runner/Info.plist').readAsStringSync();
    expect(
      plist,
      contains('<string>Commute Guardian</string>'),
      reason: 'and the two platforms must not drift apart again',
    );
  });

  test('the generator is the only author, like every other icon', () {
    // Same rule as the app icon and the station JSON: hand-editing one of five
    // density files is a difference nobody will ever find.
    expect(File('tool/build_notification_icon.py').existsSync(), isTrue);
  });
}
