import '../models/app_settings.dart';

/// Every sentence Travel Mode speaks that has NO Sarvam clip behind it.
///
/// The split from announcement_templates.dart is the one that matters here:
/// the sentences next door are a byte-for-byte contract with 127 stations of
/// cut audio, and a changed character there silently demotes an announcement
/// to the device TTS floor for the life of the pack. Nothing in THIS file has
/// audio cut from it, so the wording can be edited whenever it reads better.
/// Both files answer the same question ("what do we say"), and keeping them
/// apart is what stops an editable sentence being treated as a frozen one.
///
/// These lines are dynamic by nature (a route, a list of stations passed
/// during a call, an interchange with a platform number), which is the same
/// reason ADR 0001 leaves them on the device TTS floor forever.
///
/// THE HINDI AND MARATHI HERE HAVE NEVER BEEN HEARD OUT LOUD. The wording in
/// announcement_templates.dart came from the clip pack the owner auditioned on
/// 17 Jul; this file's translations are new, and no ride and no bench has
/// spoken them yet. Judge them through the device TTS voice before the
/// language picker is offered to anyone but the owner.
///
/// ENGLISH SURVIVES IN THREE PLACES, on purpose:
/// - Button names ("End journey"), because the screens are English. Speaking
///   a translated name for a button that reads "End journey" would send a
///   rider looking for something that is not there.
/// - Line names ("Central", "Trans Harbour"). The station data carries
///   Devanagari names, the LINE data does not, and Mumbai riders say these in
///   English anyway. Adding them means editing tool/build_stations.py, not
///   this file.
/// - "Travel Mode" and "Commute Guardian", which are product names.
class SpokenCopy {
  const SpokenCopy([this.language = AppLanguage.english]);

  final AppLanguage language;

  /// Spoken once as the ride goes live, ahead of [welcomeBody]. Has a bundled
  /// clip on Android (welcome_greeting.wav), which is EN only: the clip path
  /// is skipped for the other two languages by the caller.
  String welcome() => switch (language) {
    AppLanguage.english => 'Welcome to Commute Guardian.',
    AppLanguage.hindi => 'कम्यूट गार्जियन में आपका स्वागत है।',
    AppLanguage.marathi => 'कम्यूट गार्जियनमध्ये आपले स्वागत आहे.',
  };

  /// The route confirmation, and the app's proof through the earphones that
  /// the whole audio path works before the rider needs it.
  String welcomeBody({required String origin, required String destination}) =>
      switch (language) {
        AppLanguage.english =>
          'Travel Mode is on, from $origin to $destination. I will announce '
              'each station along the way. To end the journey at any time, '
              'press and hold the End journey button.',
        AppLanguage.hindi =>
          'ट्रैवल मोड चालू है, $origin से $destination तक। मैं रास्ते का हर '
              'स्टेशन बताऊँगा। यात्रा कभी भी खत्म करने के लिए, End journey '
              'बटन को दबाकर रखें।',
        AppLanguage.marathi =>
          'ट्रॅव्हल मोड चालू आहे, $origin ते $destination. मी वाटेतील प्रत्येक '
              'स्टेशन सांगेन. प्रवास कधीही थांबवण्यासाठी, End journey बटण '
              'दाबून धरा.',
      };

  /// The debug screen's text-to-speech self test.
  String testAnnouncement() => switch (language) {
    AppLanguage.english =>
      'This is a test announcement from Commute Guardian. If you can hear '
          'this, text to speech is working.',
    AppLanguage.hindi =>
      'यह कम्यूट गार्जियन की जाँच के लिए घोषणा है। अगर आपको यह सुनाई दे रहा '
          'है, तो टेक्स्ट टू स्पीच काम कर रहा है।',
    AppLanguage.marathi =>
      'ही कम्यूट गार्जियनची चाचणी घोषणा आहे. तुम्हाला हे ऐकू येत असेल, तर '
          'टेक्स्ट टू स्पीच काम करत आहे.',
  };

  /// Change trains here, and walk to a different station to do it (Dadar
  /// Central to Dadar Western).
  String interchangeWalk({
    required String station,
    required String walkTo,
    required String line,
    required String towards,
    String? platform,
  }) => switch (language) {
    AppLanguage.english =>
      'You have reached $station. Get off the train and walk across to '
          '$walkTo, then ${_platformThen(platform)}board the $line train '
          'towards $towards to continue to your destination.',
    AppLanguage.hindi =>
      'आप $station पहुँच गए हैं। ट्रेन से उतरें और $walkTo तक पैदल जाएँ, फिर '
          '${_platformThen(platform)}$towards की ओर जाने वाली $line ट्रेन में '
          'चढ़ें और अपनी यात्रा जारी रखें।',
    AppLanguage.marathi =>
      'तुम्ही $station आला आहात. गाडीतून उतरा आणि $walkTo पर्यंत चालत जा, '
          'नंतर ${_platformThen(platform)}$towards च्या दिशेने जाणारी $line '
          'गाडी पकडा आणि प्रवास सुरू ठेवा.',
  };

  /// Change trains where both services are spoken the same way (the Kasara
  /// branch onto the Karjat branch: both are just "Central"). Named by
  /// direction, because "change here to the Central line" while sitting on a
  /// Central train is nonsense.
  String interchangeSameService({
    required String station,
    required String towards,
    String? platform,
  }) => switch (language) {
    AppLanguage.english =>
      'You have reached $station. Change trains here. Get off the train, '
          '${_platformThen(platform)}board the train towards $towards to '
          'continue to your destination.',
    AppLanguage.hindi =>
      'आप $station पहुँच गए हैं। यहाँ ट्रेन बदलें। ट्रेन से उतरें, '
          '${_platformThen(platform)}$towards की ओर जाने वाली ट्रेन में चढ़ें '
          'और अपनी यात्रा जारी रखें।',
    AppLanguage.marathi =>
      'तुम्ही $station आला आहात. येथे गाडी बदला. गाडीतून उतरा, '
          '${_platformThen(platform)}$towards च्या दिशेने जाणारी गाडी पकडा '
          'आणि प्रवास सुरू ठेवा.',
  };

  /// The ordinary same-station change onto a differently named line.
  String interchangeLine({
    required String station,
    required String line,
    String? platform,
  }) => switch (language) {
    AppLanguage.english =>
      'You have reached $station. Change here to the $line line. Get off '
          'the train, ${_platformThen(platform)}board the $line train to '
          'continue to your destination.',
    AppLanguage.hindi =>
      'आप $station पहुँच गए हैं। यहाँ $line लाइन पर बदलें। ट्रेन से उतरें, '
          '${_platformThen(platform)}$line ट्रेन में चढ़ें और अपनी यात्रा '
          'जारी रखें।',
    AppLanguage.marathi =>
      'तुम्ही $station आला आहात. येथे $line लाईनवर बदला. गाडीतून उतरा, '
          '${_platformThen(platform)}$line गाडी पकडा आणि प्रवास सुरू ठेवा.',
  };

  /// "go to platform number 9, 10, or 10 A, then ", or nothing when the
  /// platform is unknown. Sparse by design: an interchange with no platform
  /// in the data still announces the change.
  String _platformThen(String? platform) {
    if (platform == null) return '';
    return switch (language) {
      AppLanguage.english => 'go to platform number $platform, then ',
      AppLanguage.hindi => 'प्लेटफ़ॉर्म नंबर $platform पर जाएँ, फिर ',
      AppLanguage.marathi => 'प्लॅटफॉर्म क्रमांक $platform वर जा, नंतर ',
    };
  }

  /// The call ended and the stop went by while it ran: no lead time is left,
  /// so this opens at the firm rung and says so without overclaiming.
  String postCallPassedStop(String station) => switch (language) {
    AppLanguage.english =>
      'While you were on your call, the train passed your stop, $station. '
          'Please get off the train now.',
    AppLanguage.hindi =>
      'आप कॉल पर थे, तब ट्रेन आपका स्टेशन $station पार कर गई। कृपया अभी '
          'ट्रेन से उतरें।',
    AppLanguage.marathi =>
      'तुम्ही कॉलवर असताना गाडी तुमचे स्टेशन $station ओलांडून गेली. कृपया '
          'आता गाडीतून उतरा.',
  };

  /// The same moment, but the train is AT the stop rather than past it.
  String postCallReachedStop(String station) => switch (language) {
    AppLanguage.english =>
      'While you were on your call, the train reached your stop, $station. '
          'Get off the train now.',
    AppLanguage.hindi =>
      'आप कॉल पर थे, तब ट्रेन आपके स्टेशन $station पर पहुँच गई। अभी ट्रेन '
          'से उतरें।',
    AppLanguage.marathi =>
      'तुम्ही कॉलवर असताना गाडी तुमच्या स्टेशन $station वर पोहोचली. आता '
          'गाडीतून उतरा.',
  };

  /// Re-orientation after a call, not a history replay: what the call
  /// swallowed, then the check-in it doubles as.
  String postCallCatchUp({
    required String stations,
    required String checkIn,
  }) => switch (language) {
    AppLanguage.english =>
      'While you were on your call, the train passed $stations. $checkIn',
    AppLanguage.hindi =>
      'आप कॉल पर थे, तब ट्रेन $stations पार कर गई। $checkIn',
    AppLanguage.marathi =>
      'तुम्ही कॉलवर असताना गाडी $stations ओलांडून गेली. $checkIn',
  };

  /// "Thane, Kalwa and Mumbra", in this language's conjunction.
  String joinNames(List<String> names) {
    if (names.length == 1) return names.first;
    final and = switch (language) {
      AppLanguage.english => 'and',
      AppLanguage.hindi => 'और',
      AppLanguage.marathi => 'आणि',
    };
    return '${names.sublist(0, names.length - 1).join(', ')} '
        '$and ${names.last}';
  }

  /// The wrong-direction pin was reached. States what happened and what to
  /// do; it deliberately asks no question, because the app has no
  /// notification button to answer one with.
  String wrongDirection(String destination) => switch (language) {
    AppLanguage.english =>
      'You seem to be heading away from $destination. If this is the wrong '
          'train, get off at the next station and cross to the other '
          'platform. Travel Mode is still on.',
    AppLanguage.hindi =>
      'लगता है आप $destination से दूर जा रहे हैं। अगर यह गलत ट्रेन है, तो '
          'अगले स्टेशन पर उतरें और दूसरे प्लेटफ़ॉर्म पर जाएँ। ट्रैवल मोड चालू है।',
    AppLanguage.marathi =>
      'तुम्ही $destination पासून दूर जात आहात असे दिसते. ही चुकीची गाडी असेल, '
          'तर पुढील स्टेशनवर उतरा आणि दुसऱ्या प्लॅटफॉर्मवर जा. ट्रॅव्हल मोड '
          'चालू आहे.',
  };

  /// Two minutes with no usable fix. Promises that the ride is still
  /// running, and does NOT promise to keep counting stations, because
  /// without fixes it cannot.
  String signalWeak() => switch (language) {
    AppLanguage.english =>
      'The signal is weak here. Travel Mode is still on. If you can, move '
          'near a door or a window.',
    AppLanguage.hindi =>
      'यहाँ सिग्नल कमज़ोर है। ट्रैवल मोड चालू है। हो सके तो दरवाज़े या खिड़की '
          'के पास जाएँ।',
    AppLanguage.marathi =>
      'येथे सिग्नल कमकुवत आहे. ट्रॅव्हल मोड चालू आहे. शक्य असेल तर दरवाजा '
          'किंवा खिडकीजवळ जा.',
  };

  /// A stall. Gentle, and it says nothing about why: the app cannot tell a
  /// signal failure at Diva from a chain snatching at Mumbra, and a guess is
  /// the thing a rider quotes back at it.
  String trainHeldUp() => switch (language) {
    AppLanguage.english =>
      'The train seems to be held up. Travel Mode is still on and I am '
          'still watching for your stop.',
    AppLanguage.hindi =>
      'ट्रेन रुकी हुई लगती है। ट्रैवल मोड चालू है और मैं आपके स्टेशन पर नज़र '
          'रखे हूँ।',
    AppLanguage.marathi =>
      'गाडी थांबलेली दिसते. ट्रॅव्हल मोड चालू आहे आणि मी तुमच्या स्टेशनवर लक्ष '
          'ठेवत आहे.',
  };

  /// Four hours with no end. A rider still aboard has half an hour to answer
  /// it; one who is not will simply never hear it.
  String rideTimeoutWarning() => switch (language) {
    AppLanguage.english =>
      'Travel Mode has been on for four hours. It will switch itself off in '
          'half an hour unless you are still travelling.',
    AppLanguage.hindi =>
      'ट्रैवल मोड चार घंटे से चालू है। अगर आप अब भी यात्रा नहीं कर रहे हैं, '
          'तो यह आधे घंटे में अपने आप बंद हो जाएगा।',
    AppLanguage.marathi =>
      'ट्रॅव्हल मोड चार तासांपासून चालू आहे. तुम्ही अजूनही प्रवास करत नसाल, '
          'तर तो अर्ध्या तासात आपोआप बंद होईल.',
  };

  /// The rider has walked out of the station: the one-minute countdown.
  String windDownStarted() => switch (language) {
    AppLanguage.english =>
      'Looks like you have left the station. Travel Mode will end in one '
          'minute. Use the notification to end it now, or keep it running '
          'longer.',
    AppLanguage.hindi =>
      'लगता है आप स्टेशन से निकल गए हैं। ट्रैवल मोड एक मिनट में बंद हो जाएगा। '
          'इसे अभी बंद करने या और चलाने के लिए नोटिफ़िकेशन का इस्तेमाल करें।',
    AppLanguage.marathi =>
      'तुम्ही स्टेशनमधून बाहेर पडला आहात असे दिसते. ट्रॅव्हल मोड एका मिनिटात '
          'बंद होईल. तो आताच बंद करण्यासाठी किंवा आणखी चालू ठेवण्यासाठी '
          'नोटिफिकेशन वापरा.',
  };

  /// The rider pressed Extend.
  String windDownExtended() => switch (language) {
    AppLanguage.english => 'Travel Mode will stay on for ten more minutes.',
    AppLanguage.hindi => 'ट्रैवल मोड दस मिनट और चालू रहेगा।',
    AppLanguage.marathi => 'ट्रॅव्हल मोड आणखी दहा मिनिटे चालू राहील.',
  };
}
