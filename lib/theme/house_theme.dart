import 'package:flutter/material.dart';

/// "House Lights Down" - the visual identity for The Bully League.
///
/// THE SUBJECT IS A COMEDY CLUB, NOT A FIRE. The obvious palette for a
/// roast app is a heat gradient - orange to red, flames - and it is the
/// first thing anyone reaches for, including the version of this app that
/// shipped before this file existed. It says "spicy" and nothing else.
///
/// What this app actually is: a dark room, one hard light, and an audience
/// you cannot see deciding whether you were funny. That last part is
/// literally true here - your judges are strangers watching later - so the
/// room is where the identity comes from.
///
/// THE SIGNATURE IS THE SPOTLIGHT (see [spotlight]). The performer is lit
/// and everyone else is in shadow, which turns the format's own rule -
/// one person talks, the other is muted - into something you feel rather
/// than read. It is the rule people most often break in a first match.
///
/// The type is deliberately WIDE. Every competitive app reaches for a
/// condensed face; Archivo's width axis pushed the other way reads loud
/// and confident and is far rarer.
class House {
  const House._();

  // --- the room ----------------------------------------------------------

  /// The room with the lights down. Warm-cast rather than a true black:
  /// a pure #000 reads as "OLED tech product", and this is a venue.
  static const house = Color(0xFF12100F);

  /// Deep velvet. A SURFACE colour - cards, sheets, raised things - never
  /// an accent. Curtains are the backdrop, not the act.
  static const curtain = Color(0xFF4A1220);

  /// The pool of light, and therefore the primary text.
  static const spot = Color(0xFFF5E6C8);

  /// Mic hardware and the filament in the bulb. THE ONE ACCENT, and it
  /// means exactly one thing: this is live, or this is your turn. Spending
  /// it anywhere else is what would make the spotlight stop meaning
  /// anything.
  static const brass = Color(0xFFC98A2B);

  /// Everything not currently lit: inactive text, dividers, the other
  /// player while you are talking.
  static const smoke = Color(0xFF6E6A66);

  /// Used only where something has genuinely gone wrong. Distinct from
  /// [curtain] so a failure never reads as decoration.
  static const alarm = Color(0xFFE05252);

  // --- the signature -----------------------------------------------------

  /// The spotlight: a warm pool that falls on whoever is performing.
  ///
  /// Painted as a radial gradient rather than a glow or a border, because
  /// a real spotlight has a soft edge and no outline. [intensity] fades
  /// the whole thing so a turn can come up and go down rather than
  /// snapping, which is what makes it read as lighting rather than as a
  /// selection highlight.
  static Gradient spotlight({double intensity = 1}) {
    final i = intensity.clamp(0.0, 1.0);
    return RadialGradient(
      center: const Alignment(0, -0.15),
      radius: 0.95,
      colors: [
        brass.withValues(alpha: 0.30 * i),
        brass.withValues(alpha: 0.12 * i),
        Colors.transparent,
      ],
      stops: const [0.0, 0.45, 1.0],
    );
  }

  /// What an unlit half of the screen gets: not black, but the room.
  static Color shadow(double intensity) =>
      house.withValues(alpha: (0.72 * intensity.clamp(0.0, 1.0)));

  // --- type --------------------------------------------------------------

  /// Display: Archivo pushed WIDE on its width axis.
  ///
  /// The width is the whole point, so it is set here once rather than left
  /// to each call site to remember.
  static TextStyle display({
    required double size,
    double weight = 800,
    double width = 120,
    Color? color,
    double letterSpacing = 0.5,
  }) {
    return TextStyle(
      fontFamily: 'Archivo',
      fontSize: size,
      height: 1.02,
      color: color ?? spot,
      letterSpacing: letterSpacing,
      fontVariations: [
        FontVariation('wght', weight),
        FontVariation('wdth', width),
      ],
    );
  }

  /// The full theme. Dark only for now - the app already defaults to dark
  /// (CLAUDE.md's Theming decision), and a venue with the house lights up
  /// is a different room, so a light variant needs its own design pass
  /// rather than an inverted palette.
  static ThemeData dark() {
    const scheme = ColorScheme.dark(
      primary: brass,
      onPrimary: house,
      secondary: brass,
      onSecondary: house,
      surface: house,
      onSurface: spot,
      surfaceContainerHighest: Color(0xFF241C1B),
      surfaceContainer: Color(0xFF1B1716),
      outline: smoke,
      error: alarm,
      onError: house,
      primaryContainer: curtain,
      onPrimaryContainer: spot,
    );

    final base = ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: house,
      fontFamily: 'Inter',
    );

    return base.copyWith(
      textTheme: base.textTheme.copyWith(
        headlineLarge: display(size: 34),
        headlineMedium: display(size: 28),
        headlineSmall: display(size: 23),
        titleLarge: display(size: 19, weight: 700, width: 112),
        // Body stays Inter and stays quiet. The boldness is spent in one
        // place, and that place is the display face and the light.
        bodyLarge: const TextStyle(fontFamily: 'Inter', color: spot),
        bodyMedium: const TextStyle(fontFamily: 'Inter', color: spot),
        bodySmall: const TextStyle(fontFamily: 'Inter', color: smoke),
        labelSmall: TextStyle(
          fontFamily: 'Inter',
          color: smoke,
          letterSpacing: 1.4,
          fontWeight: FontWeight.w600,
        ),
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: house,
        surfaceTintColor: Colors.transparent,
        centerTitle: false,
        titleTextStyle: display(size: 18, weight: 700, width: 118),
        iconTheme: const IconThemeData(color: smoke),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: brass,
          foregroundColor: house,
          // Size(0, h) rather than Size.fromHeight(h): fromHeight sets
          // minWidth to INFINITY, which is fine for a full-width button
          // and fatal for one inside a Row - it forces infinite width and
          // the whole subtree fails to lay out. That is what blanked the
          // entire Home screen the first time this theme was applied,
          // taking every button with it while the app bar rendered fine.
          minimumSize: const Size(0, 52),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(4),
          ),
          textStyle: display(size: 16, weight: 800, width: 116,
              letterSpacing: 1.1),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: spot,
          side: const BorderSide(color: smoke),
          minimumSize: const Size(0, 48),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(4),
          ),
          textStyle: const TextStyle(
            fontFamily: 'Inter',
            fontWeight: FontWeight.w600,
            fontSize: 15,
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(foregroundColor: brass),
      ),
      // Square-ish rather than pill-shaped: a venue's signage and a fight
      // card are built from rectangles, and Material's default rounding is
      // the single loudest tell that a screen is a stock Flutter app.
      cardTheme: CardThemeData(
        color: scheme.surfaceContainer,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(6),
          side: const BorderSide(color: Color(0xFF2A2422)),
        ),
      ),
      dividerTheme: const DividerThemeData(
        color: Color(0xFF2A2422),
        thickness: 1,
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: const Color(0xFF171312),
        indicatorColor: brass.withValues(alpha: 0.18),
        surfaceTintColor: Colors.transparent,
        labelTextStyle: WidgetStatePropertyAll(
          TextStyle(
            fontFamily: 'Inter',
            fontSize: 11,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.3,
            color: smoke,
          ),
        ),
        iconTheme: WidgetStateProperty.resolveWith(
          (states) => IconThemeData(
            color: states.contains(WidgetState.selected) ? brass : smoke,
          ),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: const Color(0xFF241C1B),
        contentTextStyle: const TextStyle(fontFamily: 'Inter', color: spot),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(4),
        ),
        behavior: SnackBarBehavior.floating,
      ),
      progressIndicatorTheme: const ProgressIndicatorThemeData(
        color: brass,
        linearTrackColor: Color(0xFF2A2422),
      ),
    );
  }
}
