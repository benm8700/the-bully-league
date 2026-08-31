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
    this.signature = 'none',
    this.segmentedGauge = false,
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

  /// The one distinctive treatment this direction is remembered by,
  /// per the design principle of spending boldness in a single place.
  /// 'glow' (neon sign), 'segments' (arcade power bar), 'frame'
  /// (collectible card). 'none' for the plain directions.
  final String signature;

  /// Whether the rank gauge is a chunky segmented power bar rather
  /// than a smooth fill. Shared by both finalists.
  final bool segmentedGauge;

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
    String? signature,
    bool? segmentedGauge,
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
      signature: signature ?? this.signature,
      segmentedGauge: segmentedGauge ?? this.segmentedGauge,
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
      signature: t < 0.5 ? signature : other.signature,
      segmentedGauge: t < 0.5 ? segmentedGauge : other.segmentedGauge,
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
//
// DECIDED (2026-08-26): 'card' is the chosen BASE theme (first = default),
// and 'neon' is preserved as the earmarked future UNLOCKABLE prestige skin
// (a strong "GOAT edition" candidate) rather than shipped as the base. Both
// stay in this list for now so the dev palette toggle can still flip the
// base between them - the developer may switch to Neon later. The other 8
// directions' builders are kept below and can be restored by adding an id.
const List<String> kThemeIds = [
  'card',
  'neon',
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
    case 'fightnight':
      return _fightNight();
    case 'comic':
      return _comic();
    case 'battle':
      return _battle();
    case 'card':
      return _card();
    case 'tape':
      return _tape();
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
        elevation: palette.signature == 'glow' ? 10 : 0,
        shadowColor: palette.signature == 'glow'
            ? scheme.primary
            : Colors.transparent,
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
      segmentedGauge: true,
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

// --- 4. NEON: 1am street. Indigo glow. -----------------------------------
//
// The "Indigo" purple, chosen by the developer (2026-08-28) from five
// purple takes: a cooler, blue-leaning periwinkle-violet on a blue-black
// night, with a mono-purple segmented power bar and the neon glow. (The
// original violet + lime two-tone is in git history.)
ThemeData _neon() {
  const night = Color(0xFF08081A); // blue-black
  const indigo = Color(0xFF5A3BF0); // deepened so WHITE button text reads
  const glow = Color(0xFF8E86FF); // brighter periwinkle, for text
  const scheme = ColorScheme.dark(
    // White button text, per the developer's call. A neon sign is lit
    // white-hot at its core; the colour is the glow around it.
    primary: indigo, onPrimary: Color(0xFFFFFFFF),
    secondary: glow, onSecondary: Color(0xFF0B0713),
    surface: night, onSurface: Color(0xFFEDE7FA),
    onSurfaceVariant: Color(0xFF9186AE),
    surfaceContainer: Color(0xFF160E24),
    surfaceContainerHigh: Color(0xFF1D1430),
    surfaceContainerHighest: Color(0xFF261A3E),
    outline: Color(0xFF3B2D57), outlineVariant: Color(0xFF2A2043),
    error: Color(0xFFFF6B8A), onError: Color(0xFF0B0713),
    inverseSurface: Color(0xFFEDE7FA), onInverseSurface: Color(0xFF0B0713),
    primaryContainer: Color(0xFF2A1650), onPrimaryContainer: indigo,
  );
  return _build(
    brightness: Brightness.dark,
    scheme: scheme,
    bodyFont: 'Inter',
    palette: const AppPalette(
      name: 'Neon',
      accent: glow,
      gaugeFrom: indigo, gaugeTo: Color(0xFFAAA0FF),
      gelA: glow, gelB: Color(0xFF5FE0FF),
      display: 'Archivo', displayWeight: 800, displayWidth: 108,
      radius: 14,
      signature: 'glow',
      segmentedGauge: true,
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

// --- 6. FIGHT NIGHT: title-fight poster. The tale of the tape. ------------
ThemeData _fightNight() {
  const canvas = Color(0xFF131114); // dark neutral, the arena
  const bone = Color(0xFFECE3D6);
  const blood = Color(0xFFD21F3C);
  const scheme = ColorScheme.dark(
    primary: blood, onPrimary: bone,
    secondary: bone, onSecondary: canvas,
    surface: canvas, onSurface: bone,
    onSurfaceVariant: Color(0xFF938A83),
    surfaceContainer: Color(0xFF1D1A1E),
    surfaceContainerHigh: Color(0xFF241F26),
    surfaceContainerHighest: Color(0xFF2C262E),
    outline: Color(0xFF453E48), outlineVariant: Color(0xFF322C34),
    error: Color(0xFFE0685A), onError: canvas,
    inverseSurface: bone, onInverseSurface: canvas,
    primaryContainer: Color(0xFF3A0E17), onPrimaryContainer: bone,
  );
  return _build(
    brightness: Brightness.dark, scheme: scheme, bodyFont: 'Inter',
    palette: const AppPalette(
      name: 'Fight Night',
      accent: blood,
      gaugeFrom: Color(0xFF7A1520), gaugeTo: blood,
      gelA: blood, gelB: Color(0xFF4E86C6),
      display: 'Archivo', displayWeight: 900, displayWidth: 68,
      radius: 0,
    ),
  );
}

// --- 7. COMIC: halftone panels and speech bubbles. Roasts ARE speech. -----
ThemeData _comic() {
  const paper = Color(0xFFF7F4EC);
  const ink = Color(0xFF141019);
  const pop = Color(0xFF1F5EFF); // pop-art electric blue
  const scheme = ColorScheme.light(
    primary: pop, onPrimary: Color(0xFFFFFFFF),
    secondary: ink, onSecondary: paper,
    surface: paper, onSurface: ink,
    onSurfaceVariant: Color(0xFF565064),
    surfaceContainer: Color(0xFFEDE9DE),
    surfaceContainerHigh: Color(0xFFE6E1D3),
    surfaceContainerHighest: Color(0xFFDED8C7),
    outline: Color(0xFF141019), outlineVariant: Color(0xFF9C96A6),
    error: Color(0xFFE5342B), onError: paper,
    inverseSurface: ink, onInverseSurface: paper,
    primaryContainer: Color(0xFFD5E0FF), onPrimaryContainer: ink,
  );
  return _build(
    brightness: Brightness.light, scheme: scheme, bodyFont: 'Inter',
    palette: const AppPalette(
      name: 'Comic',
      accent: pop,
      gaugeFrom: Color(0xFF8FB0FF), gaugeTo: pop,
      gelA: Color(0xFFE5342B), gelB: Color(0xFF178A4C),
      display: 'Archivo', displayWeight: 850, displayWidth: 120,
      radius: 2,
    ),
  );
}

// --- 8. BATTLE: graffiti / battle-rap. The audience's own culture. --------
ThemeData _battle() {
  const concrete = Color(0xFF1A1A1D);
  const chalk = Color(0xFFEDEDE8);
  const spray = Color(0xFFFF5A1F); // construction orange-red, not amber
  const scheme = ColorScheme.dark(
    primary: spray, onPrimary: Color(0xFF12100E),
    secondary: Color(0xFF35E06B), onSecondary: Color(0xFF12100E),
    surface: concrete, onSurface: chalk,
    onSurfaceVariant: Color(0xFF8C8C86),
    surfaceContainer: Color(0xFF242427),
    surfaceContainerHigh: Color(0xFF2C2C30),
    surfaceContainerHighest: Color(0xFF353539),
    outline: Color(0xFF4A4A4E), outlineVariant: Color(0xFF343438),
    error: Color(0xFFFF5A5A), onError: Color(0xFF12100E),
    inverseSurface: chalk, onInverseSurface: concrete,
    primaryContainer: Color(0xFF3A1608), onPrimaryContainer: spray,
  );
  return _build(
    brightness: Brightness.dark, scheme: scheme, bodyFont: 'Inter',
    palette: const AppPalette(
      name: 'Battle',
      accent: spray,
      gaugeFrom: Color(0xFF35E06B), gaugeTo: spray,
      gelA: Color(0xFFFF2E88), gelB: Color(0xFF35E06B),
      display: 'Archivo', displayWeight: 900, displayWidth: 110,
      radius: 2,
    ),
  );
}

// --- 9. CARD: collectible / holo. Every roaster is a card. ----------------
//
// The base now wears the "AURORA" look, chosen by the developer (2026-08-28)
// over the original teal foil: brighter cyan accent, a cooler/glassier
// slate surface, rounder corners, and a mint->cyan gauge. Softer and more
// holographic. (The original teal foil is in git history if ever wanted.)
ThemeData _card() {
  const slate = Color(0xFF0F131D);
  const frost = Color(0xFFE8ECF5);
  const cyan = Color(0xFF22D3EE); // holographic aurora cyan
  const scheme = ColorScheme.dark(
    primary: cyan, onPrimary: Color(0xFF04121A),
    secondary: Color(0xFF7DE8C4), onSecondary: Color(0xFF04121A),
    surface: slate, onSurface: frost,
    onSurfaceVariant: Color(0xFF8390A8),
    surfaceContainer: Color(0xFF17202E),
    surfaceContainerHigh: Color(0xFF1E2838),
    surfaceContainerHighest: Color(0xFF263143),
    outline: Color(0xFF3A4759), outlineVariant: Color(0xFF232F3E),
    error: Color(0xFFFF6B7D), onError: Color(0xFF04121A),
    inverseSurface: frost, onInverseSurface: slate,
    primaryContainer: Color(0xFF0A3A3F), onPrimaryContainer: cyan,
  );
  return _build(
    brightness: Brightness.dark, scheme: scheme, bodyFont: 'Inter',
    palette: const AppPalette(
      name: 'Card',
      accent: cyan,
      // Mint -> cyan, a cool aurora sweep. Solid smooth fill, not the
      // segmented power bar - a continuous stat bar sits better inside the
      // foil frame than an arcade-cabinet health bar.
      gaugeFrom: Color(0xFF34E0B0), gaugeTo: cyan,
      gelA: Color(0xFFFF6B9D), gelB: Color(0xFF6BA9FF),
      display: 'Archivo', displayWeight: 720, displayWidth: 118,
      radius: 20,
      signature: 'frame',
      segmentedGauge: false,
    ),
  );
}


// --- 10. TAPE: camcorder / VHS. The app's own output is tape. -------------
ThemeData _tape() {
  const tape = Color(0xFF0C0D0B);
  const white = Color(0xFFE6EFE6);
  const phosphor = Color(0xFF6AE86A);
  const scheme = ColorScheme.dark(
    primary: phosphor, onPrimary: Color(0xFF071007),
    secondary: white, onSecondary: tape,
    surface: tape, onSurface: white,
    onSurfaceVariant: Color(0xFF7C877C),
    surfaceContainer: Color(0xFF151714),
    surfaceContainerHigh: Color(0xFF1C1F1B),
    surfaceContainerHighest: Color(0xFF242822),
    outline: Color(0xFF39403A), outlineVariant: Color(0xFF282D28),
    error: Color(0xFFFF5C7A), onError: Color(0xFF071007),
    inverseSurface: white, onInverseSurface: tape,
    primaryContainer: Color(0xFF0F2A0F), onPrimaryContainer: phosphor,
  );
  return _build(
    brightness: Brightness.dark, scheme: scheme, bodyFont: 'Inter',
    palette: const AppPalette(
      name: 'Tape',
      accent: phosphor,
      gaugeFrom: Color(0xFF2E7A2E), gaugeTo: phosphor,
      gelA: Color(0xFFFF5C7A), gelB: Color(0xFF57C7FF),
      display: 'Archivo', displayWeight: 800, displayWidth: 100,
      radius: 2,
    ),
  );
}
