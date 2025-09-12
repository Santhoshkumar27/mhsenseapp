// lib/main.dart
import 'package:flutter/material.dart';
import 'pages/home_page.dart';

// ---- App Theme (light & dark) ----
class _AppColors {
  // Core palette (soft indigo, mint, pink, lilac)
  static const primary = Color(0xFF6C7CFF);
  static const secondary = Color(0xFF7BDFF2);
  static const tertiary = Color(0xFFFFA6C9);
  static const lilac = Color(0xFFD5CCFF);

  // Light surfaces
  static const bgLight = Color(0xFFF7F8FC);
  static const surfaceLight = Colors.white;

  // Dark surfaces
  static const bgDark = Color(0xFF0F1115);
  static const surfaceDark = Color(0xFF171A21);
}

class AppTheme {
  static ThemeData get light {
    final base = ColorScheme.fromSeed(seedColor: _AppColors.primary).copyWith(
      secondary: _AppColors.secondary,
      tertiary: _AppColors.tertiary,
      surface: _AppColors.surfaceLight,
      background: _AppColors.bgLight,
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: base,
      scaffoldBackgroundColor: _AppColors.bgLight,
      appBarTheme: AppBarTheme(
        centerTitle: true,
        elevation: 0,
        backgroundColor: base.surface,
        foregroundColor: base.onSurface,
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        margin: const EdgeInsets.all(0),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          elevation: 0,
          shape: const StadiumBorder(),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          elevation: 0,
          shape: const StadiumBorder(),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
        ),
      ),
      chipTheme: ChipThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        side: BorderSide.none,
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: base.surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: base.inverseSurface,
        contentTextStyle: TextStyle(color: base.onInverseSurface),
      ),
      visualDensity: VisualDensity.standard,
    );
  }

  static ThemeData get dark {
    final base = ColorScheme.fromSeed(
      seedColor: _AppColors.primary,
      brightness: Brightness.dark,
    ).copyWith(
      secondary: _AppColors.secondary,
      tertiary: _AppColors.tertiary,
      surface: _AppColors.surfaceDark,
      background: _AppColors.bgDark,
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: base,
      scaffoldBackgroundColor: _AppColors.bgDark,
      appBarTheme: AppBarTheme(
        centerTitle: true,
        elevation: 0,
        backgroundColor: base.surface,
        foregroundColor: base.onSurface,
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        margin: const EdgeInsets.all(0),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          elevation: 0,
          shape: const StadiumBorder(),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          elevation: 0,
          shape: const StadiumBorder(),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
        ),
      ),
      chipTheme: ChipThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        side: BorderSide.none,
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: base.surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: base.inverseSurface,
        contentTextStyle: TextStyle(color: base.onInverseSurface),
      ),
      visualDensity: VisualDensity.standard,
    );
  }
}

void main() => runApp(const SenseApp());

class SenseApp extends StatelessWidget {
  const SenseApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Sense',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.system,
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      home: const HomePage(),
    );
  }
}