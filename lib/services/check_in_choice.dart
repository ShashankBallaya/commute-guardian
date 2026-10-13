/// Whether the earphone tap can reach us, read from the iPhone's answer to the
/// ladder's session seizure, or null when [note] is not that answer.
///
/// WHY THE CHECK-IN NEEDS THIS, 13 Oct 2026. The check-in always said "Tap
/// your earphones, or press the I am awake button". On an iPhone with the
/// rider's music playing and the phone in a pocket, iOS refuses us the
/// exclusive session (CannotInterruptOthers), the music keeps the buttons, and
/// the tap skips a track. Four rides on 19, 20 and 23 Sep were all acked from
/// the screen for exactly that reason. So the check-in now asks only for the
/// screen button when the tap cannot work.
///
/// ONLY THE LADDER-START NOTE COUNTS. AppDelegate.startAckSession returns
/// `ladder session MODE`, where MODE is "exclusive", "ducked (...)" or
/// "NONE (...)". The tone's later re-seizes say "tone (re)started, session
/// ..." and answer a different question, so they are ignored here.
/// test/check_in_choice_test.dart pins the Swift strings, because Swift only
/// compiles in CI.
bool? earphoneAckFromSessionNote(String note) {
  const prefix = 'ladder session ';
  if (!note.startsWith(prefix)) return null;
  return note.substring(prefix.length).startsWith('exclusive');
}
