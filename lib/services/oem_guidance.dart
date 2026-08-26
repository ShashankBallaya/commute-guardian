/// The second permission, the one Android has no API for.
///
/// WHY THIS EXISTS. OEM battery killers are this project's named top product
/// risk, and the app already does everything the platform offers: it holds a
/// foreground service, it requests the battery-optimisation exemption, and
/// Settings reports all of it. On a Xiaomi, Oppo, Realme, Vivo, OnePlus,
/// Samsung or Huawei phone that is NOT ENOUGH. Those skins keep a second list
/// (autostart, auto launch, background usage limits) that decides whether an
/// app may run at all, and it has no public API: it cannot be read, cannot be
/// set, and cannot be detected. A ride can die on a phone whose every row in
/// Settings is green.
///
/// SO THIS IS NOT A STATUS, IT IS INSTRUCTIONS. The readiness card's own rule
/// is that a row which can never go green must not be drawn, and nothing here
/// can ever go green. What the rider gets instead is their own phone's steps,
/// a button that opens the screen where those steps happen when the platform
/// will resolve one, and a way to say they have done it. The acknowledgement
/// is the rider's word, and it is recorded as exactly that.
///
/// THE COHORT IS THE REASON IT IS BUILT NOW. Of the alpha riders, Shruti is on
/// the only ColorOS phone, which is the highest-risk skin of the set, and the
/// 3T is OxygenOS. A ride lost to this looks identical to a bug in the
/// geofence chain, and it would be chased as one.
library;

import 'package:flutter/services.dart';

/// The phone, in its own words.
class OemDevice {
  const OemDevice({
    this.manufacturer = '',
    this.brand = '',
    this.model = '',
    this.sdkInt,
  });

  static const unknown = OemDevice();

  factory OemDevice.fromPlatform(Map<Object?, Object?>? payload) {
    if (payload == null) return unknown;
    String text(String key) => (payload[key] as String?)?.trim() ?? '';
    return OemDevice(
      manufacturer: text('manufacturer'),
      brand: text('brand'),
      model: text('model'),
      sdkInt: (payload['sdkInt'] as num?)?.toInt(),
    );
  }

  /// `Build.MANUFACTURER`, e.g. `Xiaomi`. The brand is carried beside it
  /// because they differ where it matters most: a Redmi or a POCO reports
  /// `Xiaomi` as the manufacturer and its own name as the brand, and the
  /// rider only recognises the second one.
  final String manufacturer;
  final String brand;
  final String model;
  final int? sdkInt;
}

/// The skins that keep a second list, grouped by the steps they need.
enum OemFamily {
  /// MIUI and HyperOS: Xiaomi, Redmi, POCO.
  xiaomi,

  /// ColorOS: Oppo.
  oppo,

  /// Realme UI, which is ColorOS underneath with its own names.
  realme,

  /// Funtouch OS and OriginOS: Vivo, iQOO.
  vivo,

  /// OxygenOS.
  oneplus,

  /// One UI. No autostart list, but Sleeping apps does the same damage.
  samsung,

  /// EMUI and MagicOS: Huawei, Honor.
  huawei,

  /// Everything else, including stock Android, Motorola, Nothing and Pixel.
  /// The platform exemption is the whole story on these.
  none,
}

/// What to tell the rider, and what to call their phone while doing it.
class OemGuidance {
  const OemGuidance({
    required this.family,
    required this.brandLabel,
    required this.steps,
  });

  final OemFamily family;

  /// The name on the back of the phone, not the corporate one. A POCO owner
  /// does not think of their phone as a Xiaomi.
  final String brandLabel;

  /// The steps, in order, in the skin's own words. Menu names are quoted from
  /// the skin because a rider is matching them against what is on screen, and
  /// a paraphrase is a rider who gives up halfway.
  final List<String> steps;

  /// Whether this phone needs anything beyond what the app already asks for.
  bool get needsAttention => family != OemFamily.none;
}

/// Which family a phone belongs to. PURE, so every phone in the cohort can be
/// answered at this desk without holding it.
OemFamily oemFamilyFor({required String manufacturer, String brand = ''}) {
  final maker = manufacturer.toLowerCase().trim();
  final name = brand.toLowerCase().trim();
  bool says(String needle) => maker == needle || name == needle;

  // REALME BEFORE OPPO, and the order is load-bearing. Realme phones report
  // `realme` as the manufacturer, but some report an Oppo brand string, and
  // the two skins name their menus differently. Matching Oppo first would put
  // ColorOS wording in front of a Realme UI rider.
  if (says('realme')) return OemFamily.realme;
  if (says('xiaomi') || says('redmi') || says('poco')) return OemFamily.xiaomi;
  if (says('oppo')) return OemFamily.oppo;
  if (says('vivo') || says('iqoo')) return OemFamily.vivo;
  if (says('oneplus')) return OemFamily.oneplus;
  if (says('samsung')) return OemFamily.samsung;
  if (says('huawei') || says('honor')) return OemFamily.huawei;
  return OemFamily.none;
}

/// The guidance for a phone, ready to draw.
OemGuidance oemGuidanceFor(OemDevice device) {
  final family = oemFamilyFor(
    manufacturer: device.manufacturer,
    brand: device.brand,
  );
  return OemGuidance(
    family: family,
    brandLabel: _brandLabel(device, family),
    steps: _steps[family] ?? const [],
  );
}

String _brandLabel(OemDevice device, OemFamily family) {
  // The brand, when the phone gives one, because that is the word on the back
  // of it. Falls back to the manufacturer, then to something true and vague.
  final source = device.brand.isNotEmpty ? device.brand : device.manufacturer;
  if (source.isEmpty) return 'phone';
  // Skins report these lower case. Anything already capitalised is left alone,
  // because OnePlus and iQOO are not Oneplus and Iqoo.
  if (source == source.toLowerCase()) {
    return source[0].toUpperCase() + source.substring(1);
  }
  return source;
}

const _steps = <OemFamily, List<String>>{
  OemFamily.xiaomi: [
    'Open Security, then Permissions, then Autostart.',
    'Turn Autostart ON for Commute Guardian.',
    'Open Settings, then Battery, then App battery saver.',
    'Find Commute Guardian and set it to No restrictions.',
    'Open the app switcher, hold this app down, and tap the padlock.',
  ],
  OemFamily.oppo: [
    'Open Settings, then Battery, then More battery settings.',
    'Turn Allow auto launch ON for Commute Guardian.',
    'Open Settings, then Apps, then Commute Guardian.',
    'Open Battery usage and choose Allow background activity.',
    'Open the app switcher, pull this app down, and tap Lock.',
  ],
  OemFamily.realme: [
    'Open Settings, then Battery, then App battery management.',
    'Find Commute Guardian and turn Allow auto launch ON.',
    'In the same place, turn Allow background running ON.',
    'Open Settings, then Apps, then Commute Guardian, then Battery usage.',
    'Choose Allow background activity.',
  ],
  OemFamily.vivo: [
    'Open i Manager, then App manager, then Autostart manager.',
    'Turn Autostart ON for Commute Guardian.',
    'Open Settings, then Battery, then Background power consumption.',
    'Add Commute Guardian to the allowed list.',
  ],
  OemFamily.oneplus: [
    'Open Settings, then Battery, then Battery optimisation.',
    'Find Commute Guardian and choose Do not optimise.',
    'Open Settings, then Apps, then Commute Guardian, then Battery.',
    'Turn Allow background activity ON.',
    'Open the app switcher, tap the menu on this app, and tap Lock.',
  ],
  OemFamily.samsung: [
    'Open Settings, then Battery, then Background usage limits.',
    'Check that Commute Guardian is NOT in Sleeping apps or Deep sleeping '
        'apps. Remove it if it is there.',
    'Open Settings, then Apps, then Commute Guardian, then Battery.',
    'Choose Unrestricted.',
  ],
  OemFamily.huawei: [
    'Open Phone Manager, then App launch.',
    'Turn Manage automatically OFF for Commute Guardian.',
    'Turn ON all three: Auto launch, Secondary launch, Run in background.',
  ],
};

/// Reads the phone and opens the OEM screen. A CLASS SO IT CAN BE FAKED, like
/// every other platform edge here.
class OemGateway {
  const OemGateway();

  static const _channel = MethodChannel('commute_guardian/oem');

  /// The phone in its own words, or [OemDevice.unknown] where there is no
  /// channel: iOS, a test binding, or a desktop host. Unknown means
  /// [OemFamily.none], which shows the rider nothing, which is right.
  Future<OemDevice> describe() async {
    try {
      final payload = await _channel.invokeMethod<Map<Object?, Object?>>(
        'describe',
      );
      return OemDevice.fromPlatform(payload);
    } catch (_) {
      return OemDevice.unknown;
    }
  }

  /// Opens the skin's own autostart screen and returns the component that
  /// answered, or null when nothing on this phone did.
  ///
  /// NULL IS A REAL ANSWER AND THE UI USES IT. These components differ by skin
  /// version and several are no longer exported, so the button is offered only
  /// where one resolves. A button that does nothing is worse than no button,
  /// especially on the screen whose whole job is telling someone how to fix
  /// something.
  Future<String?> openAutoStart() async {
    try {
      return await _channel.invokeMethod<String>('openAutoStart');
    } catch (_) {
      return null;
    }
  }
}
