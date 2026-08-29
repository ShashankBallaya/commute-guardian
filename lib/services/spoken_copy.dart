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

  /// The route, spoken while the rider can still take it back.
  ///
  /// THE EYES-FREE HALF OF THE COMMIT WINDOW. Screen 3's window exists so a
  /// mis-tap never becomes a ride, and Kalyan and Kalwa are one fat-finger
  /// apart in the picker. A rider who taps and pockets the phone never sees
  /// the ring, so the catch has to arrive through the earphones, which is this
  /// app's primary channel anyway.
  ///
  /// "STARTING", NOT "IS ON", and the tense is the whole point. This is spoken
  /// while Cancel is still live and the ride may never happen. `welcomeBody`
  /// is allowed to claim the ride is running because by then it is.
  ///
  /// NO SARVAM CLIP EXISTS FOR THIS LINE, so it speaks in device TTS until one
  /// is cut, and it is the first thing a rider hears on every journey.
  String startingRoute({required String origin, required String destination}) =>
      switch (language) {
        AppLanguage.english =>
          'Starting Travel Mode, from $origin to $destination.',
        AppLanguage.hindi =>
          'ट्रैवल मोड शुरू हो रहा है, $origin से $destination तक।',
        AppLanguage.marathi =>
          'ट्रॅव्हल मोड सुरू होत आहे, $origin ते $destination पर्यंत.',
      };

  /// The route confirmation, and the app's proof through the earphones that
  /// the whole audio path works before the rider needs it.
  ///
  /// [routeAlreadySpoken] shortens it to drop the origin and destination,
  /// because [startingRoute] has just said them and a rider does not need the
  /// same two station names twice in five seconds. It keeps "Travel Mode is
  /// on", which is now TRUE and is the one thing the window could not claim.
  /// False on every path that has no window: a resume from Screen 1, and the
  /// unattended relaunch, where this is the only route confirmation there is.
  String welcomeBody({
    required String origin,
    required String destination,
    bool routeAlreadySpoken = false,
  }) => routeAlreadySpoken
      ? switch (language) {
          AppLanguage.english =>
            'Travel Mode is on. I will announce each station along the way. '
                'To end the journey at any time, press and hold the End '
                'journey button.',
          AppLanguage.hindi =>
            'ट्रैवल मोड चालू है। रास्ते में हर स्टेशन की घोषणा की जाएगी। '
                'यात्रा कभी भी समाप्त करने के लिए End journey बटन को दबाकर '
                'रखें।',
          AppLanguage.marathi =>
            'ट्रॅव्हल मोड सुरू आहे. मार्गातील प्रत्येक स्टेशनची घोषणा केली '
                'जाईल. प्रवास कधीही संपवण्यासाठी End journey बटण दाबून धरून '
                'ठेवा.',
        }
      : switch (language) {
          AppLanguage.english =>
            'Travel Mode is on, from $origin to $destination. I will announce '
                'each station along the way. To end the journey at any time, '
                'press and hold the End journey button.',
          AppLanguage.hindi =>
            'ट्रैवल मोड चालू है, $origin से $destination तक। रास्ते में हर '
                'स्टेशन की घोषणा की जाएगी। यात्रा कभी भी समाप्त करने के लिए '
                'End journey बटन को दबाकर रखें।',
          AppLanguage.marathi =>
            'ट्रॅव्हल मोड सुरू आहे, $origin ते $destination पर्यंत. मार्गातील '
                'प्रत्येक स्टेशनची घोषणा केली जाईल. प्रवास कधीही संपवण्यासाठी '
                'End journey बटण दाबून धरून ठेवा.',
        };

  /// The debug screen's text-to-speech self test.
  String testAnnouncement() => switch (language) {
    AppLanguage.english =>
      'This is a test announcement from Commute Guardian. If you can hear '
          'this, text to speech is working.',
    AppLanguage.hindi =>
      'यह कम्यूट गार्जियन की परीक्षण घोषणा है। अगर आपको यह सुनाई दे रही '
          'है, तो टेक्स्ट टू स्पीच काम कर रहा है।',
    AppLanguage.marathi =>
      'ही कम्यूट गार्जियनची चाचणी घोषणा आहे. हे आपल्याला ऐकू येत असेल, तर '
          'टेक्स्ट टू स्पीच व्यवस्थित काम करत आहे.',
  };

  /// The rider asked for the far side of a foot overbridge, so the ride ends
  /// on the near side and the last few metres are on foot (ask for Prabhadevi
  /// from a Central train and the train puts you at Parel).
  ///
  /// SPOKEN AFTER THE ARRIVAL SENTENCE, never instead of it. The arrival names
  /// the platform the rider is standing on, which is the fact they need first;
  /// this adds the one they came for. It says "across the foot overbridge"
  /// rather than "nearby" because the bridge is the whole reason these two
  /// rows are one place, and a rider who looks for a bridge finds one.
  String destinationAcrossBridge(String station) => switch (language) {
    AppLanguage.english => '$station is just across the foot overbridge.',
    AppLanguage.hindi => '$station यहीं पास, फुट ओवरब्रिज के उस पार है।',
    AppLanguage.marathi =>
      '$station येथून जवळच, फूट ओव्हरब्रिजच्या पलीकडे आहे.',
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
          '$walkTo, then board the $line train towards $towards'
          '${_platformFrom(platform)}.',
    AppLanguage.hindi =>
      'आप $station पहुँच गए हैं। ट्रेन से उतरें और पैदल चलकर $walkTo पहुँचें, '
          'फिर ${_platformFrom(platform)}$towards की ओर जाने वाली $line ट्रेन '
          'में चढ़ें।',
    AppLanguage.marathi =>
      'आपण $station येथे पोहोचलात. ट्रेनमधून उतरा आणि पायी चालत $walkTo येथे '
          'जा, त्यानंतर ${_platformFrom(platform)}$towards च्या दिशेने जाणारी '
          '$line ट्रेन घ्या.',
  };

  /// The far half of a walk interchange, once the rider has actually crossed
  /// to it. It is a CONFIRMATION, not an arrival: the rider walked here, so
  /// "now approaching" would be nonsense, and what they need to hear is that
  /// they are on the right side of the bridge and which train to take.
  ///
  /// The platform number is deliberately absent. [interchangeWalk] has already
  /// said it, a minute earlier, at the moment the rider had to decide where to
  /// walk. Repeating it here would lengthen the one announcement that competes
  /// with a train pulling in.
  String walkArrived({
    required String station,
    required String line,
    required String towards,
  }) => switch (language) {
    AppLanguage.english =>
      'You are at $station. Take the $line train towards $towards.',
    AppLanguage.hindi =>
      'आप $station पर हैं। $towards की ओर जाने वाली $line ट्रेन लें।',
    AppLanguage.marathi =>
      'आपण $station येथे आहात. $towards च्या दिशेने जाणारी $line ट्रेन घ्या.',
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
      'आप $station पहुँच गए हैं। यहाँ ट्रेन बदलें। ट्रेन से उतरें और '
          '${_platformThen(platform)}$towards की ओर जाने वाली ट्रेन में चढ़ें, '
          'ताकि आप अपने गंतव्य तक पहुँच सकें।',
    AppLanguage.marathi =>
      'आपण $station येथे पोहोचलात. येथे ट्रेन बदला. ट्रेनमधून उतरा आणि '
          '${_platformThen(platform)}$towards च्या दिशेने जाणाऱ्या ट्रेनमध्ये '
          'चढा, आणि आपले गंतव्य गाठा.',
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
      'आप $station पहुँच गए हैं। यहाँ $line लाइन की ट्रेन में बदलें। ट्रेन से '
          'उतरें और ${_platformThen(platform)}$line ट्रेन में चढ़ें, ताकि आप '
          'अपने गंतव्य तक पहुँच सकें।',
    AppLanguage.marathi =>
      'आपण $station येथे पोहोचलात. येथे $line लाईनची ट्रेन घ्या. ट्रेनमधून '
          'उतरा आणि ${_platformThen(platform)}$line ट्रेनमध्ये चढा, आणि आपले '
          'गंतव्य गाठा.',
  };

  /// "go to platform number 9, 10, or 10 A, then ", or nothing when the
  /// platform is unknown. Sparse by design: an interchange with no platform
  /// in the data still announces the change.
  /// The platform as a phrase that attaches to "board the X train", rather
  /// than as a step of its own.
  ///
  /// [interchangeWalk] used [_platformThen] until 29 Aug 2026 and read "walk
  /// across to Dadar Western, THEN go to platform number 2 or 4, THEN board the
  /// Western train towards Churchgate to continue to your destination". Two
  /// "then"s turned one instruction into a three-step list, and at the app's
  /// measured 2.6 words a second (30 words of welcome in 11,571 ms on the
  /// 28 Aug ride) that sentence ran 13.5 seconds. It plays as the train draws
  /// into Dadar, over platform noise, while the rider has to stand up and reach
  /// a door. The number is worth its two seconds; the second "then" is not.
  ///
  /// English attaches it as a SUFFIX and the other two as a PREFIX, because
  /// that is where each language wants it. Each branch places the fragment
  /// itself; this only says what the fragment is.
  String _platformFrom(String? platform) {
    if (platform == null) return '';
    return switch (language) {
      AppLanguage.english => ' from platform $platform',
      AppLanguage.hindi => 'प्लेटफ़ॉर्म नंबर $platform से ',
      AppLanguage.marathi => 'प्लॅटफॉर्म क्रमांक $platform वरून ',
    };
  }

  String _platformThen(String? platform) {
    if (platform == null) return '';
    return switch (language) {
      AppLanguage.english => 'go to platform number $platform, then ',
      AppLanguage.hindi => 'प्लेटफ़ॉर्म नंबर $platform पर जाएँ, फिर ',
      AppLanguage.marathi => 'प्लॅटफॉर्म क्रमांक $platform वर जा, त्यानंतर ',
    };
  }

  /// The call ended and the stop went by while it ran: no lead time is left,
  /// so this opens at the firm rung and says so without overclaiming.
  String postCallPassedStop(String station) => switch (language) {
    AppLanguage.english =>
      'While you were on your call, the train passed your stop, $station. '
          'Please get off the train now.',
    AppLanguage.hindi =>
      'जब आप कॉल पर थे, ट्रेन आपके स्टॉप $station से आगे निकल गई। कृपया अभी '
          'ट्रेन से उतरें।',
    AppLanguage.marathi =>
      'आपण कॉलवर असताना ट्रेन आपल्या थांब्याच्या $station पुढे गेली. कृपया '
          'आता ट्रेनमधून उतरा.',
  };

  /// The same moment, but the train is AT the stop rather than past it.
  String postCallReachedStop(String station) => switch (language) {
    AppLanguage.english =>
      'While you were on your call, the train reached your stop, $station. '
          'Get off the train now.',
    AppLanguage.hindi =>
      'जब आप कॉल पर थे, ट्रेन आपके स्टॉप $station पर पहुँच गई। अब ट्रेन '
          'से उतरें।',
    AppLanguage.marathi =>
      'आपण कॉलवर असताना ट्रेन आपल्या थांब्यावर $station येथे पोहोचली. आता '
          'ट्रेनमधून उतरा.',
  };

  /// Re-orientation after a call, not a history replay: what the call
  /// swallowed, then the check-in it doubles as.
  String postCallCatchUp({required String stations, required String checkIn}) =>
      switch (language) {
        AppLanguage.english =>
          'While you were on your call, the train passed $stations. $checkIn',
        AppLanguage.hindi =>
          'जब आप कॉल पर थे, ट्रेन $stations से आगे निकल गई। $checkIn',
        AppLanguage.marathi =>
          'आपण कॉलवर असताना ट्रेन $stations पुढे गेली. $checkIn',
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
      'लगता है कि आप $destination से दूर जा रहे हैं। अगर यह गलत ट्रेन है, तो '
          'अगले स्टेशन पर उतरें और दूसरे प्लेटफ़ॉर्म पर जाएँ। ट्रैवल मोड अभी '
          'भी चालू है।',
    AppLanguage.marathi =>
      'आपण $destination पासून दूर जात असल्याचे दिसत आहे. ही चुकीची ट्रेन '
          'असल्यास, पुढच्या स्टेशनवर उतरा आणि दुसऱ्या प्लॅटफॉर्मवर जा. '
          'ट्रॅव्हल मोड अजूनही सुरू आहे.',
  };

  /// Two minutes with no usable fix. Promises that the ride is still
  /// running, and does NOT promise to keep counting stations, because
  /// without fixes it cannot.
  String signalWeak() => switch (language) {
    AppLanguage.english =>
      'The signal is weak here. Travel Mode is still on. If you can, move '
          'near a door or a window.',
    AppLanguage.hindi =>
      'यहाँ सिग्नल कमज़ोर है। ट्रैवल मोड अभी भी चालू है। अगर संभव हो, तो '
          'दरवाज़े या खिड़की के पास जाएँ।',
    AppLanguage.marathi =>
      'येथे सिग्नल कमकुवत आहे. ट्रॅव्हल मोड अजूनही सुरू आहे. शक्य असल्यास, '
          'दरवाज्याजवळ किंवा खिडकीजवळ जा.',
  };

  /// A stall. Gentle, and it says nothing about why: the app cannot tell a
  /// signal failure at Diva from a chain snatching at Mumbra, and a guess is
  /// the thing a rider quotes back at it.
  String trainHeldUp() => switch (language) {
    AppLanguage.english =>
      'The train seems to be held up. Travel Mode is still on and I am '
          'still watching for your stop.',
    AppLanguage.hindi =>
      'लगता है कि ट्रेन को आगे जाने में देरी हो रही है। ट्रैवल मोड अभी भी '
          'चालू है और आपके स्टॉप पर नज़र रखी जा रही है।',
    AppLanguage.marathi =>
      'ट्रेनला पुढे जाण्यास विलंब होत असल्याचे दिसत आहे. ट्रॅव्हल मोड अजूनही '
          'सुरू आहे आणि आपल्या थांब्यावर लक्ष ठेवले जात आहे.',
  };

  /// Four hours with no end. A rider still aboard has half an hour to answer
  /// it; one who is not will simply never hear it.
  String rideTimeoutWarning() => switch (language) {
    AppLanguage.english =>
      'Travel Mode has been on for four hours. It will switch itself off in '
          'half an hour unless you are still travelling.',
    AppLanguage.hindi =>
      'ट्रैवल मोड चार घंटे से चालू है। अगर आप अभी भी यात्रा नहीं कर रहे हैं, '
          'तो यह आधे घंटे में अपने आप बंद हो जाएगा।',
    AppLanguage.marathi =>
      'ट्रॅव्हल मोड चार तासांपासून सुरू आहे. आपला प्रवास अजूनही सुरू नसेल, '
          'तर ते अर्ध्या तासात आपोआप बंद होईल.',
  };

  /// The rider has walked out of the station: the one-minute countdown.
  String windDownStarted() => switch (language) {
    AppLanguage.english =>
      'Looks like you have left the station. Travel Mode will end in one '
          'minute. Use the notification to end it now, or keep it running '
          'longer.',
    AppLanguage.hindi =>
      'लगता है कि आप स्टेशन से बाहर निकल गए हैं। ट्रैवल मोड एक मिनट में '
          'समाप्त हो जाएगा। इसे अभी समाप्त करने के लिए नोटिफ़िकेशन का '
          'इस्तेमाल करें, या इसे और देर तक चालू रखें।',
    AppLanguage.marathi =>
      'आपण स्टेशनमधून बाहेर पडल्याचे दिसत आहे. ट्रॅव्हल मोड एका मिनिटात '
          'संपेल. ते आत्ताच संपवण्यासाठी नोटिफिकेशन वापरा, किंवा ते आणखी '
          'काही वेळ सुरू ठेवा.',
  };

  /// The rider pressed Extend.
  String windDownExtended() => switch (language) {
    AppLanguage.english => 'Travel Mode will stay on for ten more minutes.',
    AppLanguage.hindi => 'ट्रैवल मोड अगले दस मिनट तक चालू रहेगा।',
    AppLanguage.marathi => 'ट्रॅव्हल मोड आणखी दहा मिनिटे सुरू राहील.',
  };
}
