import 'package:commute_guardian/services/oem_guidance.dart';
import 'package:flutter_test/flutter_test.dart';

/// The second permission, the one Android has no API for.
///
/// EVERY PHONE IN THE COHORT IS ANSWERABLE AT THIS DESK, which is the point of
/// keeping the mapping pure. The alpha riders carry a ColorOS phone (the
/// highest-risk skin of the set), a OnePlus, and several this project has never
/// held. None of them can be borrowed to check a menu name, and a ride lost to
/// an autostart list looks exactly like a bug in the geofence chain.
void main() {
  OemGuidance guidanceFor(String manufacturer, {String brand = ''}) =>
      oemGuidanceFor(
        OemDevice(manufacturer: manufacturer, brand: brand),
      );

  group('which skin keeps a list', () {
    test('the seven that do', () {
      expect(oemFamilyFor(manufacturer: 'Xiaomi'), OemFamily.xiaomi);
      expect(oemFamilyFor(manufacturer: 'OPPO'), OemFamily.oppo);
      expect(oemFamilyFor(manufacturer: 'realme'), OemFamily.realme);
      expect(oemFamilyFor(manufacturer: 'vivo'), OemFamily.vivo);
      expect(oemFamilyFor(manufacturer: 'OnePlus'), OemFamily.oneplus);
      expect(oemFamilyFor(manufacturer: 'samsung'), OemFamily.samsung);
      expect(oemFamilyFor(manufacturer: 'HUAWEI'), OemFamily.huawei);
    });

    test('A REDMI AND A POCO ARE XIAOMI PHONES, by manufacturer', () {
      // Both report Xiaomi as the manufacturer and their own name as the
      // brand. Matching only the brand would leave the two most common budget
      // phones in Mumbai with no guidance at all.
      expect(
        oemFamilyFor(manufacturer: 'Xiaomi', brand: 'Redmi'),
        OemFamily.xiaomi,
      );
      expect(
        oemFamilyFor(manufacturer: 'Xiaomi', brand: 'POCO'),
        OemFamily.xiaomi,
      );
    });

    test('an iQOO is a vivo', () {
      expect(
        oemFamilyFor(manufacturer: 'vivo', brand: 'iQOO'),
        OemFamily.vivo,
      );
    });

    test('HONOR IS SPLIT FROM HUAWEI AS A COMPANY, not as a skin', () {
      expect(oemFamilyFor(manufacturer: 'HONOR'), OemFamily.huawei);
    });

    test('the phones that need nothing', () {
      // Stock and near-stock. The platform exemption the app already requests
      // is the whole story, and a card about a setting these phones do not
      // have is noise on the one screen a worried rider reads carefully.
      for (final maker in ['Google', 'motorola', 'Nothing', 'Sony', 'asus']) {
        expect(
          oemFamilyFor(manufacturer: maker),
          OemFamily.none,
          reason: '$maker does not keep an autostart list',
        );
      }
    });

    test('an unknown phone asks for nothing', () {
      // iOS, a test binding and a desktop host all land here. Silence is the
      // right answer: this screen can only ever be guessing on a phone that
      // will not name itself.
      expect(oemGuidanceFor(OemDevice.unknown).needsAttention, isFalse);
      expect(oemGuidanceFor(OemDevice.unknown).steps, isEmpty);
    });
  });

  group('THE ORDER OF THE CHECKS IS LOAD-BEARING', () {
    test('a realme reporting an OPPO brand is still realme', () {
      // Realme was an Oppo sub-brand and some builds still say so. ColorOS and
      // Realme UI name their menus differently, so matching Oppo first would
      // put the wrong words in front of the rider, on the screen whose entire
      // job is matching words to what is on their display.
      expect(
        oemFamilyFor(manufacturer: 'realme', brand: 'oppo'),
        OemFamily.realme,
      );
    });
  });

  group('what the rider is called and told', () {
    test('THE NAME ON THE BACK OF THE PHONE, not the corporate one', () {
      // A POCO owner does not think of their phone as a Xiaomi, and a screen
      // that opens by telling them what phone they own gets one chance.
      expect(guidanceFor('Xiaomi', brand: 'POCO').brandLabel, 'POCO');
      expect(guidanceFor('Xiaomi', brand: 'Redmi').brandLabel, 'Redmi');
    });

    test('a lower-case brand is capitalised, a styled one is left alone', () {
      expect(guidanceFor('vivo').brandLabel, 'Vivo');
      expect(guidanceFor('realme').brandLabel, 'Realme');
      // OnePlus and iQOO are not Oneplus and Iqoo.
      expect(guidanceFor('OnePlus').brandLabel, 'OnePlus');
      expect(guidanceFor('vivo', brand: 'iQOO').brandLabel, 'iQOO');
    });

    test('a phone that will not name itself is still addressable', () {
      expect(guidanceFor('').brandLabel, 'phone');
    });

    test('EVERY SKIN THAT NEEDS ATTENTION HAS STEPS', () {
      // A card that says "your phone needs one more setting" and then shows an
      // empty list is worse than showing nothing at all.
      for (final family in OemFamily.values) {
        if (family == OemFamily.none) continue;
        final guidance = OemGuidance(
          family: family,
          brandLabel: 'Test',
          steps: oemGuidanceFor(
            OemDevice(manufacturer: _makerFor(family)),
          ).steps,
        );
        expect(
          guidance.steps,
          isNotEmpty,
          reason: '$family is offered guidance and must have some',
        );
      }
    });

    test('the steps name the app, so a rider can search the OEM list', () {
      // Every one of these screens is a long alphabetical list of installed
      // apps. A step that says "turn autostart on" without saying what to turn
      // it on FOR is a step a rider cannot follow.
      for (final family in OemFamily.values) {
        if (family == OemFamily.none) continue;
        final steps = oemGuidanceFor(
          OemDevice(manufacturer: _makerFor(family)),
        ).steps;
        expect(
          steps.any((step) => step.contains('Commute Guardian')),
          isTrue,
          reason: '$family steps must name the app',
        );
      }
    });
  });

  group('what the platform said', () {
    test('a full payload', () {
      final device = OemDevice.fromPlatform({
        'manufacturer': 'Xiaomi',
        'brand': 'Redmi',
        'model': 'M2101K6G',
        'sdkInt': 33,
      });

      expect(device.manufacturer, 'Xiaomi');
      expect(device.brand, 'Redmi');
      expect(device.sdkInt, 33);
      expect(oemGuidanceFor(device).family, OemFamily.xiaomi);
    });

    test('no channel is the unknown phone, not a crash', () {
      expect(OemDevice.fromPlatform(null).manufacturer, isEmpty);
      expect(oemGuidanceFor(OemDevice.fromPlatform(null)).needsAttention,
          isFalse);
    });
  });
}

/// A manufacturer string that lands in [family]. Used to walk every family
/// without hardcoding the same list the code under test uses.
String _makerFor(OemFamily family) => switch (family) {
  OemFamily.xiaomi => 'Xiaomi',
  OemFamily.oppo => 'OPPO',
  OemFamily.realme => 'realme',
  OemFamily.vivo => 'vivo',
  OemFamily.oneplus => 'OnePlus',
  OemFamily.samsung => 'samsung',
  OemFamily.huawei => 'HUAWEI',
  OemFamily.none => 'Google',
};
