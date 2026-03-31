import 'package:flutter/material.dart';

/// لون العلامة — موحّد مع الـ FAB والشاشات التي تستخدم الكحلي.
abstract final class AppColors {
  static const Color navy = Color(0xFF101046);
}

/// Auction / live bidding accent palette (primary navy stays [AppColors.navy]).
abstract final class AuctionUiColors {
  static const Color amber = Color(0xFFF0B429);
  static const Color amberDeep = Color(0xFFD97706);
  static const Color amberDark = Color(0xFFB45309);
  static const Color urgencyRed = Color(0xFFC62828);
  static const Color winningGreen = Color(0xFF15803D);
  static const Color winningGreenLight = Color(0xFF22C55E);
}

/// ثيم فاتح بألوان أساسية كحلية بدل البنفسجي الافتراضي في Material 3.
ThemeData aqarAiLightTheme() {
  const navy = AppColors.navy;
  final scheme = ColorScheme.fromSeed(
    seedColor: navy,
    brightness: Brightness.light,
  ).copyWith(
    primary: navy,
    onPrimary: Colors.white,
    secondary: navy,
    onSecondary: Colors.white,
    tertiary: navy,
  );

  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: navy,
        foregroundColor: Colors.white,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: navy),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(foregroundColor: navy),
    ),
    floatingActionButtonTheme: const FloatingActionButtonThemeData(
      backgroundColor: navy,
      foregroundColor: Colors.white,
    ),
    radioTheme: RadioThemeData(
      fillColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) return navy;
        return null;
      }),
    ),
    checkboxTheme: CheckboxThemeData(
      fillColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) return navy;
        return null;
      }),
      checkColor: WidgetStateProperty.all(Colors.white),
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(color: navy),
  );
}
