import 'package:flutter/material.dart';

import 'palette.dart';

/// The app's one theme.
///
/// Lifted out of `CommuteGuardianDebugApp` on 4 Aug 2026 so a test can mount a
/// single screen wearing the real theme instead of booting the whole app to get
/// it. Before that, every widget test pumped the app and read whatever the
/// entry gate happened to open, which is how flipping the gate to Screen 1
/// broke eleven tests that were not about the gate at all.
ThemeData commuteGuardianTheme() {
  final base = ThemeData(brightness: Brightness.dark, useMaterial3: true);
  return base.copyWith(
    scaffoldBackgroundColor: Palette.ground,
    colorScheme: base.colorScheme.copyWith(
      surface: Palette.ground,
      primary: Palette.text,
      onSurface: Palette.text,
    ),
    textTheme: base.textTheme.apply(
      bodyColor: Palette.text,
      displayColor: Palette.text,
    ),
    // The pickers and the search sheet's field: dark wells recessed into the
    // glass surfaces, no hard borders.
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: Palette.groundDeep,
      labelStyle: TextStyle(color: Palette.textDim(0.6)),
      hintStyle: TextStyle(color: Palette.textDim(0.4)),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide.none,
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      // Opaque: a snackbar floats over whatever is on screen, and a translucent
      // fill would pick up the content behind it.
      backgroundColor: Palette.surfaceSolid,
      contentTextStyle: const TextStyle(color: Palette.text),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
      ),
    ),
  );
}
