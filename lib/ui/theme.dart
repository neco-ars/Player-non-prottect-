import 'package:flutter/material.dart';

/// Тёмная тема: почти чёрный фон, карточки чуть светлее, один яркий акцент.
class AppColors {
  static const bg = Color(0xFF121212);
  static const surface = Color(0xFF181818);
  static const card = Color(0xFF242424);
  static const cardHover = Color(0xFF2E2E2E);
  static const text = Colors.white;
  static const textDim = Color(0xFFB3B3B3);
  static const accent = Color(0xFFFF5A1F); // фирменный оранжевый
}

ThemeData buildTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: AppColors.accent,
    brightness: Brightness.dark,
  ).copyWith(
    primary: AppColors.accent,
    onPrimary: Colors.black,
    surface: AppColors.bg,
    onSurface: AppColors.text,
    onSurfaceVariant: AppColors.textDim,
    surfaceContainer: AppColors.surface,
    surfaceContainerHigh: AppColors.card,
    surfaceContainerHighest: AppColors.cardHover,
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: AppColors.bg,
    appBarTheme: const AppBarTheme(
      backgroundColor: AppColors.bg,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      titleTextStyle: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: AppColors.text),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: Colors.black,
      indicatorColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      height: 62,
      labelTextStyle: WidgetStateProperty.resolveWith((s) => TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: s.contains(WidgetState.selected) ? AppColors.text : AppColors.textDim,
          )),
      iconTheme: WidgetStateProperty.resolveWith(
          (s) => IconThemeData(color: s.contains(WidgetState.selected) ? AppColors.text : AppColors.textDim, size: 26)),
    ),
    bottomSheetTheme: const BottomSheetThemeData(backgroundColor: AppColors.surface, surfaceTintColor: Colors.transparent),
    dialogTheme: const DialogThemeData(backgroundColor: AppColors.card, surfaceTintColor: Colors.transparent),
    listTileTheme: const ListTileThemeData(iconColor: AppColors.textDim),
    sliderTheme: const SliderThemeData(
      trackHeight: 4,
      activeTrackColor: AppColors.text,
      inactiveTrackColor: Color(0x4DFFFFFF),
      thumbColor: AppColors.text,
      overlayShape: RoundSliderOverlayShape(overlayRadius: 14),
      thumbShape: RoundSliderThumbShape(enabledThumbRadius: 6),
    ),
    snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
  );
}
