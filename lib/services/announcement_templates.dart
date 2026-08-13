import '../models/app_settings.dart';

/// The sentences a station announcement is built from, in one place, in every
/// language Travel Mode speaks.
///
/// Three things have to agree on this wording byte for byte: the engines
/// that speak it (RideProgress, WakeEscalation), the clip lookup that
/// decides a Sarvam clip may stand in for an utterance, and
/// tool/build_clip_pack.py, which cut the clips from the same wording. It
/// lived in all three by hand until a review found the two overshoot
/// copies wrapping at different points, which made byte-identity
/// impossible to check by eye. The Dart side now renders from here, and
/// test/announcement_templates_test.dart pins every sentence to a literal
/// so the Python clip factory has one documented contract to match.
///
/// EVERYTHING IN THIS FILE IS CLIP-BACKED, and that is what separates it from
/// spoken_copy.dart next door. A sentence here has a `.wav` cut from it for
/// all 127 stations in all three languages, so a single changed character
/// silently demotes that announcement back to the device TTS floor for the
/// rest of the pack's life. Sentences with no clip (the welcome, the
/// interchange scripts, the health warnings) live in spoken_copy.dart, where
/// the wording may be edited freely.
///
/// The Hindi and Marathi wording is the copy the owner auditioned when the
/// pack was cut (build_clip_pack.py, 17 Jul), moved here unchanged. It was
/// never in the Dart code until now: the app spoke English in all three
/// languages, because nothing on this side knew the other two existed.
enum ClipKind {
  approach('approach'),
  passed('passed'),
  overshoot('overshoot'),
  destination('destination');

  const ClipKind(this.fileSuffix);

  /// The clip pack's filename fragment: `{stationId}__{fileSuffix}.wav`.
  final String fileSuffix;

  /// The sentence for a station, exactly as the device TTS floor speaks it
  /// and exactly as the clip was cut.
  ///
  /// [stationName] must already be in [language]: use
  /// `station.nameIn(language)`. Rendering a Hindi sentence around an English
  /// name is the mid-sentence voice switch ADR 0001 refuses for clips, and it
  /// reads just as badly on the TTS floor.
  String render(
    String stationName, {
    AppLanguage language = AppLanguage.english,
  }) => switch (language) {
    AppLanguage.english => switch (this) {
      ClipKind.approach => 'Now approaching $stationName.',
      ClipKind.passed => 'You have passed $stationName.',
      ClipKind.overshoot =>
        'You have passed your stop. It is alright. Please alight here, '
            'at $stationName.',
      ClipKind.destination =>
        'You have arrived at your destination, $stationName.',
    },
    AppLanguage.hindi => switch (this) {
      ClipKind.approach => 'अब $stationName पहुँचने वाला है।',
      ClipKind.passed => 'आप $stationName से आगे निकल चुके हैं।',
      ClipKind.overshoot =>
        'आप अपने स्टॉप से आगे निकल चुके हैं। कोई बात नहीं। कृपया यहीं, '
            '$stationName पर उतरें।',
      ClipKind.destination =>
        'आप अपने गंतव्य $stationName पर पहुँच गए हैं।',
    },
    AppLanguage.marathi => switch (this) {
      ClipKind.approach => 'आता $stationName येत आहे.',
      ClipKind.passed => 'आपण $stationName मागे सोडले आहे.',
      ClipKind.overshoot =>
        'आपण आपल्या थांब्याच्या पुढे निघून गेला आहात. काही हरकत नाही. '
            'कृपया येथेच, $stationName येथे उतरा.',
      ClipKind.destination =>
        'आपण आपल्या गंतव्यस्थानी $stationName येथे पोहोचलात.',
    },
  };
}

/// The wake ladder's spoken rungs, per station, in every language.
///
/// These moved out of wake_escalation.dart, which held them as English
/// literals with a comment asking the reader to keep them in step with
/// build_clip_pack.py by hand. That is the same arrangement the station
/// templates had before a review found them already drifted.
///
/// [checkInChange] has NO clip and never had one: the pack cuts a check-in
/// for the destination only. It is here anyway, because a rider changing
/// trains hears it from the same engine in the same breath, and splitting one
/// ladder's copy across two files by which lines happen to have audio would be
/// the drift this file exists to stop.
enum WakeLine {
  /// "Your stop, X, is next. Tap your earphones ..."
  checkIn('wake_checkin'),

  /// The same check-in for an interchange rather than the destination.
  checkInChange(null),

  /// The firm rung: "Wake up! Wake up. Your stop, X, is next."
  wakeUpStop('wake_up_stop'),

  /// The firm rung for an interchange.
  wakeUpChange('wake_up_change');

  const WakeLine(this.fileSuffix);

  /// The clip pack's filename fragment, or null when no clip was cut.
  final String? fileSuffix;

  String render(
    String stationName, {
    AppLanguage language = AppLanguage.english,
  }) => switch (language) {
    AppLanguage.english => switch (this) {
      WakeLine.checkIn =>
        'Your stop, $stationName, is next. Tap your earphones, or press '
            'the I am awake button, to show you are awake.',
      WakeLine.checkInChange =>
        'Your train change at $stationName is next. Tap your earphones, '
            'or press the I am awake button, to show you are awake.',
      WakeLine.wakeUpStop =>
        'Wake up! Wake up. Your stop, $stationName, is next.',
      WakeLine.wakeUpChange =>
        'Wake up! Wake up. Your train change at $stationName is next.',
    },
    AppLanguage.hindi => switch (this) {
      WakeLine.checkIn =>
        'आपका स्टॉप $stationName अगला है। जागने का संकेत देने के लिए अपने '
            'ईयरफ़ोन पर टैप करें, या स्क्रीन पर दिए बटन को दबाएँ।',
      WakeLine.checkInChange =>
        '$stationName पर ट्रेन बदलनी है, वह अगला स्टेशन है। जागने का संकेत '
            'देने के लिए अपने ईयरफ़ोन पर टैप करें, या स्क्रीन पर दिए बटन को '
            'दबाएँ।',
      WakeLine.wakeUpStop => 'जागिए! जागिए। आपका स्टॉप $stationName अगला है।',
      WakeLine.wakeUpChange =>
        'जागिए! जागिए। $stationName पर ट्रेन बदलनी है, वह अगला स्टेशन है।',
    },
    AppLanguage.marathi => switch (this) {
      WakeLine.checkIn =>
        'आपला थांबा $stationName पुढचा आहे. आपण जागे आहात हे दाखवण्यासाठी '
            'आपल्या ईअरफोनवर टॅप करा, किंवा स्क्रीनवरील बटण दाबा.',
      WakeLine.checkInChange =>
        '$stationName येथे ट्रेन बदलायची आहे, हे पुढचे स्टेशन आहे. आपण जागे '
            'आहात हे दाखवण्यासाठी आपल्या ईअरफोनवर टॅप करा, किंवा स्क्रीनवरील '
            'बटण दाबा.',
      WakeLine.wakeUpStop =>
        'जागे व्हा! जागे व्हा. आपला थांबा $stationName पुढचा आहे.',
      WakeLine.wakeUpChange =>
        'जागे व्हा! जागे व्हा. $stationName येथे ट्रेन बदलायची आहे, हे पुढचे '
            'स्टेशन आहे.',
    },
  };
}

/// Whole sentences with no station name in them, cut once per language rather
/// than once per station (`_fixed__{fileSuffix}.wav`).
enum FixedLine {
  /// Spoken as Travel Mode ends.
  farewell('farewell'),

  /// The answer to an acknowledged wake ladder.
  goodAwake('good_awake');

  const FixedLine(this.fileSuffix);

  final String fileSuffix;

  String render({AppLanguage language = AppLanguage.english}) =>
      switch (language) {
        AppLanguage.english => switch (this) {
          FixedLine.farewell => 'Thank you for using Commute Guardian.',
          FixedLine.goodAwake => 'Good, you are awake.',
        },
        AppLanguage.hindi => switch (this) {
          FixedLine.farewell => 'कम्यूट गार्जियन इस्तेमाल करने के लिए धन्यवाद।',
          FixedLine.goodAwake => 'बहुत अच्छा, आप जाग गए।',
        },
        AppLanguage.marathi => switch (this) {
          FixedLine.farewell => 'कम्यूट गार्जियन वापरल्याबद्दल धन्यवाद.',
          FixedLine.goodAwake => 'छान, तुम्ही जागे आहात.',
        },
      };
}
