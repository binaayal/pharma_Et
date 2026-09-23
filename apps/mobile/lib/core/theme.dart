import 'package:flutter/material.dart';

/// Design tokens from docs/prototype/index.html.
///
/// The prototype is visual intent only: a screen that looks right but violates the sync
/// contract or tenant isolation is still wrong.
abstract final class PharmaColors {
  static const paper = Color(0xFFF5F7F6);
  static const ink = Color(0xFF14201B);
  static const muted = Color(0xFF5B6B64);
  static const faint = Color(0xFF8A9791);
  static const line = Color(0xFFDCE3E0);
  static const card = Color(0xFFFFFFFF);

  static const green = Color(0xFF1F6E5C);
  static const greenDark = Color(0xFF0E3B31);
  static const greenTint = Color(0xFFE7F0EC);
  static const amber = Color(0xFFB26A12);
  static const amberTint = Color(0xFFFBEFDD);
  static const red = Color(0xFFB4322A);
  static const redTint = Color(0xFFF7E4E2);
}

ThemeData buildTheme() {
  final base = ThemeData(
    useMaterial3: true,
    colorScheme: ColorScheme.fromSeed(
      seedColor: PharmaColors.green,
      primary: PharmaColors.green,
      surface: PharmaColors.paper,
    ),
  );

  return base.copyWith(
    scaffoldBackgroundColor: PharmaColors.paper,
    appBarTheme: const AppBarTheme(
      backgroundColor: PharmaColors.green,
      foregroundColor: Colors.white,
      elevation: 0,
    ),
    cardTheme: CardThemeData(
      color: PharmaColors.card,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: const BorderSide(color: PharmaColors.line),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: PharmaColors.green,
        minimumSize: const Size.fromHeight(52),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: Colors.white,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: PharmaColors.line),
      ),
    ),
  );
}
