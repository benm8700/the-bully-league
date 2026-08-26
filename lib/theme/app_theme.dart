import 'package:flutter/material.dart';

/// The swappable visual identity for The Bully League.
///
/// Five directions live here so the developer can flip through them in the
/// running app and pick one. This is a FIRST PASS per direction: real
/// colours, type and shape applied app-wide, with the judging screens
/// (Battle, Ranks, the gauge) tuned - not five finished products.
///
/// WHY A THEME EXTENSION. Most of the app already reads
/// `Theme.of(context).colorScheme`, which swaps for free. But a handful of
/// tokens are semantic to THIS product and have no Material slot: the two
/// player "gels" that tell opponents apart, and the gauge fill. Those live
/// on [AppPalette] so they swap with everything else instead of being
/// frozen constants. Read them with `context.palette`.
///
/// WHAT EACH DIRECTION DELIBERATELY AVOIDS: the current app was told it
/// looked like Grindr - black plus an amber-orange accent. None of these
/// five sit in that corner. Two lean light (Grindr never does), and no
/// dark one uses a warm single accent.
@immutable
class AppPalette extends ThemeExtension<AppPalette> {
  const AppPalette({
    required this.accent,
    required this.gaugeFrom,
    required this.gaugeTo,
    required this.gelA,
    required this.gelB,
    required this.display,
    required this.displayWeight,
    required this.displayWidth,
    required this.radius,
    required this.name,
  });

  /// The one colour that means "primary action / live". Mirrors
  /// colorScheme.primary but named for intent.
  final Color accent;

  /// The rank gauge fill, low end to high end.
  final Color gaugeFrom;
  final Color gaugeTo;

  /// The two player colours, used only where both appear and neither is
  /// performing - vote screen, tally, feed. Never the accent.
  final Color gelA;
  final Color gelB;

  /// The display face and how it is set. Held here so every direction can
  /// choose its own without each widget knowing which.
  final String display;
  final double displayWeight;
  final double displayWidth; // 100 = normal; only Archivo honours this.

  /// Corner radius for buttons and cards - a real personality lever.
  final double radius;

  final String name;

  @override
  AppPalette copyWith({
    Color? accent,
    Color? gaugeFrom,
    Color? gaugeTo,
    Color? gelA,
    Color? gelB,
    String? display,
    double? displayWeight,
    double? displayWidth,
    double? radius,
    String? name,
  }) {
    return AppPalette(
      accent: accent ?? this.accent,
      gaugeFrom: gaugeFrom ?? this.gaugeFrom,
      gaugeTo: gaugeTo ?? this.gaugeTo,
      gelA: gelA ?? this.gelA,
      gelB: gelB ?? this.gelB,
      display: display ?? this.display,
      displayWeight: displayWeight ?? this.displayWeight,
      displayWidth: displayWidth ?? this.displayWidth,
      radius: radius ?? this.radius,
      name: name ?? this.name,
    );
  }

  @override
  AppPalette lerp(AppPalette? other, double t) {
    if (other == null) return this;
    return AppPalette(
      accent: Color.lerp(accent, other.accent, t)!,
      gaugeFrom: Color.lerp(gaugeFrom, other.gaugeFrom, t)!,
      gaugeTo: Color.lerp(gaugeTo, other.gaugeTo, t)!,
      gelA: Color.lerp(gelA, other.gelA, t)!,
      gelB: Color.lerp(gelB, other.gelB, t)!,
      display: t < 0.5 ? display : other.display,
      displayWeight: displayWeight,
      displayWidth: displayWidth,
      radius: radius,
      name: t < 0.5 ? name : other.name,
    );
  }
}

/// Convenience accessor so widgets read `context.palette.accent`.
extension PaletteContext on BuildContext {
  AppPalette get palette => Theme.of(this).extension<AppPalette>()!;
}

/// A display TextStyle in the active direction's face and setting.
TextStyle displayStyle(
  BuildContext context, {
  required double size,
  Color? color,
  double? weight,
  double letterSpacing = 0,
  double height = 1.02,
}) {
  final p = context.palette;
  return TextStyle(
    fontFamily: p.display,
    fontSize: size,
    height: height,
    color: color,
    letterSpacing: letterSpacing,
    fontVariations: [
      FontVariation('wght', weight ?? p.displayWeight),
      // Only Archivo carries a width axis; on other faces this is ignored
      // harmlessly.
      FontVariation('wdth', p.displayWidth),
    ],
  );
}

// ===========================================================================
// The five directions.
// ===========================================================================

/// Every direction, in order, keyed by id. The picker cycles this list.
const List<String> kThemeIds = [
  'tabloid',
  'arcade',
  'courtside',
  'neon',
  'riso',
];

ThemeData appTheme(String id) {
  switch (id) {
    case 'arcade':
      return _arcade();
    case 'courtside':
      return _courtside();
    case 'neon':
      return _neon();
    case 'riso':
      return _riso();
    case 'tabloid':
    default:
      return _tabloid();
  }
}

/// Shared scaffolding so each direction only states what makes it itself.
ThemeData _build({
  required Brightness brightness,
  required ColorScheme scheme,
  required AppPalette palette,
  required String bodyFont,
  Color? scaffold,
}) {
  final base = ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: scaffold ?? scheme.surface,
    fontFamily: bodyFont,
    extensions: [palette],
  );

  final r = palette.radius;
  TextStyle disp(double s, {double? w, double ls = 0}) => TextStyle(
        fontFamily: palette.display,
        fontSize: s,
        height: 1.0,
        letterSpacing: ls,
        fontVariations: [
          FontVariation('wght', w ?? palette.displayWeight),
          FontVariation('wdth', palette.displayWidth),
        ],
      );

  return base.copyWith(
    textTheme: base.textTheme.copyWith(
      headlineLarge: disp(34),
      headlineMedium: disp(28),
      headlineSmall: disp(23),
      titleLarge: disp(19, w: palette.displayWeight - 100),
      labelSmall: TextStyle(
        fontFamily: bodyFont,
        color: scheme.onSurfaceVariant,
        letterSpacing: 1.6,
        fontWeight: FontWeight.w700,
      ),
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: scaffold ?? scheme.surface,
      surfaceTintColor: Colors.transparent,
      centerTitle: false,
      titleTextStyle: disp(18, w: palette.displayWeight - 80, ls: 0.5),
      iconTheme: IconThemeData(color: scheme.onSurfaceVariant),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: scheme.primary,
        foregroundColor: scheme.onPrimary,
        minimumSize: const Size(0, 52),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(r)),
        textStyle: disp(16, ls: 0.8),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: scheme.onSurface,
        side: BorderSide(color: scheme.outline),
        minimumSize: const Size(0, 48),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(r)),
        textStyle: TextStyle(
            fontFamily: bodyFont, fontWeight: FontWeight.w600, fontSize: 15),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: scheme.primary),
    ),
    cardTheme: CardThemeData(
      color: scheme.surfaceContainer,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(r + 2),
        side: BorderSide(color: scheme.outlineVariant),
      ),
    ),
    dividerTheme: DividerThemeData(color: scheme.outlineVariant, thickness: 1),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: scheme.surfaceContainerHigh,
      indicatorColor: scheme.primary.withValues(alpha: 0.20),
      surfaceTintColor: Colors.transparent,
      labelTextStyle: WidgetStatePropertyAll(TextStyle(
        fontFamily: bodyFont,
        fontSize: 11,
        fontWeight: FontWeight.w700,
        color: scheme.onSurfaceVariant,
      )),
      iconTheme: WidgetStateProperty.resolveWith((s) => IconThemeData(
          color: s.contains(WidgetState.selected)
              ? scheme.primary
              : scheme.onSurfaceVariant)),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: scheme.inverseSurface,
      contentTextStyle:
          TextStyle(fontFamily: bodyFont, color: scheme.onInverseSurface),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(r)),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: scheme.primary,
      linearTrackColor: scheme.surfaceContainerHighest,
    ),
  );
}

// --- 1. TABLOID: supermarket front page. Loud, printed, public. ----------
ThemeData _tabloid() {
  const ink = Color(0xFF141210);
  const paper = Color(0xFFF3EFE7);
  const scream = Color(0xFFE01B24); // one screaming red
  const scheme = ColorScheme.light(
    primary: scream, onPrimary: paper,
    secondary: ink, onSecondary: paper,
    surface: paper, onSurface: ink,
    onSurfaceVariant: Color(0xFF5A554D),
    surfaceContainer: Color(0xFFEAE4D8),
    surfaceContainerHigh: Color(0xFFE3DCCE),
    surfaceContainerHighest: Color(0xFFDBD3C3),
    outline: Color(0xFF9A9184), outlineVariant: Color(0xFFCEC6B7),
    error: scream, onError: paper,
    inverseSurface: ink, onInverseSurface: paper,
    primaryContainer: Color(0xFFF7D9D9), onPrimaryContainer: ink,
  );
  return _build(
    brightness: Brightness.light,
    scheme: scheme,
    bodyFont: 'Inter',
    palette: const AppPalette(
      name: 'Tabloid',
      accent: scream,
      gaugeFrom: Color(0xFFF0A0A4), gaugeTo: scream,
      gelA: scream, gelB: Color(0xFF1C6FE0),
      display: 'Archivo', displayWeight: 900, displayWidth: 62, // condensed
      radius: 0,
    ),
  );
}

// --- 2. ARCADE: 80s cabinet. Scores, KO, high-contrast. ------------------
ThemeData _arcade() {
  const black = Color(0xFF07060C);
  const magenta = Color(0xFFFF2E88);
  const cyan = Color(0xFF22E0D6);
  const scheme = ColorScheme.dark(
    primary: magenta, onPrimary: black,
    secondary: cyan, onSecondary: black,
    surface: black, onSurface: Color(0xFFF2F0FF),
    onSurfaceVariant: Color(0xFF8A88B8),
    surfaceContainer: Color(0xFF141227),
    surfaceContainerHigh: Color(0xFF1B1833),
    surfaceContainerHighest: Color(0xFF241F42),
    outline: Color(0xFF3A3660), outlineVariant: Color(0xFF2A2749),
    error: Color(0xFFFF5A5A), onError: black,
    inverseSurface: Color(0xFFF2F0FF), onInverseSurface: black,
    primaryContainer: Color(0xFF3A0E28), onPrimaryContainer: magenta,
  );
  return _build(
    brightness: Brightness.dark,
    scheme: scheme,
    bodyFont: 'Inter',
    palette: const AppPalette(
      name: 'Arcade',
      accent: magenta,
      gaugeFrom: cyan, gaugeTo: magenta,
      gelA: magenta, gelB: cyan,
      display: 'Archivo', displayWeight: 800, displayWidth: 125,
      radius: 2,
    ),
  );
}

// --- 3. COURTSIDE: broadcast + courtroom. The crowd rules. ----------------
ThemeData _courtside() {
  const navy = Color(0xFF0C1526);
  const chalk = Color(0xFFF4F6FB);
  const gold = Color(0xFFE7B54A);
  const scheme = ColorScheme.dark(
    primary: gold, onPrimary: navy,
    secondary: chalk, onSecondary: navy,
    surface: navy, onSurface: chalk,
    onSurfaceVariant: Color(0xFF8695AE),
    surfaceContainer: Color(0xFF13203A),
    surfaceContainerHigh: Color(0xFF182747),
    surfaceContainerHighest: Color(0xFF1F3157),
    outline: Color(0xFF34456A), outlineVariant: Color(0xFF223354),
    error: Color(0xFFE06666), onError: navy,
    inverseSurface: chalk, onInverseSurface: navy,
    primaryContainer: Color(0xFF33291A), onPrimaryContainer: gold,
  );
  return _build(
    brightness: Brightness.dark,
    scheme: scheme,
    bodyFont: 'Inter',
    palette: const AppPalette(
      name: 'Courtside',
      accent: gold,
      gaugeFrom: Color(0xFF5E7BB0), gaugeTo: gold,
      gelA: Color(0xFF4E86C6), gelB: gold,
      display: 'Archivo', displayWeight: 800, displayWidth: 118,
      radius: 6,
    ),
  );
}

// --- 4. NEON: 1am street. Two-tone glow. ---------------------------------
ThemeData _neon() {
  const nearBlack = Color(0xFF0B0713);
  const violet = Color(0xFF9B5CFF);
  const lime = Color(0xFFB6FF3C);
  const scheme = ColorScheme.dark(
    primary: violet, onPrimary: Color(0xFF0B0713),
    secondary: lime, onSecondary: Color(0xFF0B0713),
    surface: nearBlack, onSurface: Color(0xFFEDE7FA),
    onSurfaceVariant: Color(0xFF9186AE),
    surfaceContainer: Color(0xFF160E24),
    surfaceContainerHigh: Color(0xFF1D1430),
    surfaceContainerHighest: Color(0xFF261A3E),
    outline: Color(0xFF3B2D57), outlineVariant: Color(0xFF2A2043),
    error: Color(0xFFFF6B8A), onError: Color(0xFF0B0713),
    inverseSurface: Color(0xFFEDE7FA), onInverseSurface: Color(0xFF0B0713),
    primaryContainer: Color(0xFF2A1650), onPrimaryContainer: violet,
  );
  return _build(
    brightness: Brightness.dark,
    scheme: scheme,
    bodyFont: 'Inter',
    palette: const AppPalette(
      name: 'Neon',
      accent: violet,
      gaugeFrom: violet, gaugeTo: lime,
      gelA: violet, gelB: lime,
      display: 'Archivo', displayWeight: 800, displayWidth: 108,
      radius: 14,
    ),
  );
}

// --- 5. RISO: zine print. Two spot inks that overprint. -------------------
ThemeData _riso() {
  const stock = Color(0xFFF2ECD8); // warm paper
  const ink = Color(0xFF201A2C);
  const pink = Color(0xFFFF3C7A); // fluoro pink spot
  const scheme = ColorScheme.light(
    primary: pink, onPrimary: stock,
    secondary: Color(0xFF2C6FE8), onSecondary: stock,
    surface: stock, onSurface: ink,
    onSurfaceVariant: Color(0xFF6B6478),
    surfaceContainer: Color(0xFFE9E2CC),
    surfaceContainerHigh: Color(0xFFE1D9C0),
    surfaceContainerHighest: Color(0xFFD8CFB2),
    outline: Color(0xFFA89F8A), outlineVariant: Color(0xFFCFC6AC),
    error: Color(0xFFD52B54), onError: stock,
    inverseSurface: ink, onInverseSurface: stock,
    primaryContainer: Color(0xFFFAD3E0), onPrimaryContainer: ink,
  );
  return _build(
    brightness: Brightness.light,
    scheme: scheme,
    bodyFont: 'Inter',
    palette: const AppPalette(
      name: 'Riso',
      accent: pink,
      gaugeFrom: Color(0xFF6FA0F0), gaugeTo: pink,
      gelA: pink, gelB: Color(0xFF2C6FE8),
      display: 'Archivo', displayWeight: 800, displayWidth: 88,
      radius: 3,
    ),
  );
}
