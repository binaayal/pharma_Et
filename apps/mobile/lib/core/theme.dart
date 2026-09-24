import 'package:flutter/material.dart';

/// Design tokens from docs/prototype/index.html — "use these exactly".
///
/// The prototype is visual intent only: a screen that looks right but violates the sync
/// contract or tenant isolation is still wrong.
abstract final class PharmaColors {
  static const paper = Color(0xFFF5F7F6);
  static const paperTop = Color(0xFFF8FAF7);
  static const ink = Color(0xFF14201B);
  static const muted = Color(0xFF5B6B64);
  static const faint = Color(0xFF8A9791);
  static const line = Color(0xFFDCE3E0);
  static const rowLine = Color(0xFFEBF0ED);
  static const card = Color(0xFFFFFFFF);

  static const green = Color(0xFF1F6E5C);
  static const greenDark = Color(0xFF0E3B31);
  static const greenTint = Color(0xFFE7F0EC);
  static const heroFrom = Color(0xFF238067);
  static const heroTo = Color(0xFF155A49);
  static const amber = Color(0xFFB26A12);
  static const amberInk = Color(0xFF7A4A0E);
  static const amberTint = Color(0xFFFBEFDD);
  static const ctaFrom = Color(0xFFE8B14B);
  static const ctaTo = Color(0xFFD7932B);
  static const ctaInk = Color(0xFF2F210D);
  static const gold = Color(0xFFEBB84B);
  static const red = Color(0xFFB4322A);
  static const redTint = Color(0xFFF7E4E2);
  static const warnFrom = Color(0xFFC64438);
  static const warnTo = Color(0xFFA52A22);
  static const blue = Color(0xFF2C5B8A);
  static const blueTint = Color(0xFFE4ECF4);
  static const segment = Color(0xFFE5EBE6);
}

/// The one easing curve the prototype uses for motion: cubic-bezier(.2,.8,.2,1).
const pharmaEase = Cubic(0.2, 0.8, 0.2, 1);

/// Soft green-tinted card shadow, as in `.tile` / `.rows`.
const cardShadow = [
  BoxShadow(color: Color(0x0E0D3B2B), blurRadius: 18, offset: Offset(0, 5)),
];

ThemeData buildTheme() {
  final base = ThemeData(
    useMaterial3: true,
    fontFamilyFallback: const ['Noto Sans Ethiopic'],
    colorScheme: ColorScheme.fromSeed(
      seedColor: PharmaColors.green,
      primary: PharmaColors.green,
      surface: PharmaColors.paper,
    ),
  );

  return base.copyWith(
    scaffoldBackgroundColor: PharmaColors.paperTop,
    textTheme: base.textTheme.apply(
      bodyColor: PharmaColors.ink,
      displayColor: PharmaColors.ink,
    ),
    pageTransitionsTheme: const PageTransitionsTheme(builders: {
      TargetPlatform.android: FadeForwardsPageTransitionsBuilder(),
    }),
    snackBarTheme: const SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: PharmaColors.greenDark,
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: PharmaColors.paperTop,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: Colors.white,
      contentPadding: const EdgeInsets.all(13),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: Color(0xFFE6ECE9)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: PharmaColors.green, width: 1.6),
      ),
      hintStyle: const TextStyle(color: PharmaColors.faint),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: PharmaColors.green,
        minimumSize: const Size(88, 44),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    ),
  );
}
