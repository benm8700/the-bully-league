import 'package:flutter/material.dart';

/// THE BACK BUTTON (2026-11-11, developer's call): big, easy to hit, and on
/// brand. A dark glass disc with a pink-to-purple neon ring and a soft glow,
/// with a bold chevron.
///
/// Used two ways:
///  - [BackBadge] is the VISUAL only. The theme hands it to every AppBar
///    back button (ActionIconThemeData.backButtonIconBuilder in
///    app_theme.dart), so every pushed screen gets it with no per-screen code.
///  - [BigBackButton] is a standalone tappable version for screens without an
///    AppBar (the full-screen Judge feed) or with a custom leading.
///
/// The disc is 52px; the hit area is 62px, comfortably over Apple's 44pt and
/// Android's 48dp minimum.
class BackBadge extends StatelessWidget {
  const BackBadge({super.key, this.size = 52, this.contained = false});

  final double size;

  /// Inside an AppBar the bar clips anything past its edges, so a wide bloom
  /// gets cut into a visible square. [contained] keeps the glow tight enough
  /// to stay inside the bar; the free-floating button (Judge) gets the full
  /// bloom.
  final bool contained;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      padding: const EdgeInsets.all(2.5),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFFFF3B8D), Color(0xFF9B4DFF)],
        ),
        // STRONGER GLOW (2026-11-11): a tight hot-pink halo plus a wide
        // purple bloom, so the button reads as lit neon on any background.
        boxShadow: contained
            ? const [
                BoxShadow(color: Color(0xDDFF3B8D), blurRadius: 8),
                BoxShadow(
                  color: Color(0x889B4DFF),
                  blurRadius: 4,
                  spreadRadius: 1,
                ),
              ]
            : const [
                BoxShadow(
                  color: Color(0xCCFF3B8D),
                  blurRadius: 12,
                  spreadRadius: 1,
                ),
                BoxShadow(
                  color: Color(0x889B4DFF),
                  blurRadius: 26,
                  spreadRadius: 4,
                ),
                BoxShadow(
                  color: Color(0x99000000),
                  blurRadius: 8,
                  offset: Offset(0, 3),
                ),
              ],
      ),
      child: Container(
        decoration: const BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(
            center: Alignment(-0.3, -0.4),
            radius: 1.0,
            colors: [Color(0xFF2A1838), Color(0xFF0E0A16)],
          ),
        ),
        alignment: Alignment.center,
        // Nudged left a hair so the chevron looks optically centred.
        child: Padding(
          padding: EdgeInsets.only(right: size * 0.04),
          child: Icon(
            Icons.arrow_back_ios_new_rounded,
            size: size * 0.46,
            color: Colors.white,
            shadows: const [
              Shadow(color: Color(0xFFFF3B8D), blurRadius: 10),
              Shadow(color: Color(0x88FFFFFF), blurRadius: 4),
            ],
          ),
        ),
      ),
    );
  }
}

/// A tappable [BackBadge] with a 56px hit area. Pops the route by default.
class BigBackButton extends StatelessWidget {
  const BigBackButton({super.key, this.onPressed});

  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null || Navigator.of(context).canPop();
    return Semantics(
      button: true,
      label: 'Back',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: enabled
            ? (onPressed ?? () => Navigator.of(context).maybePop())
            : null,
        child: Opacity(
          opacity: enabled ? 1 : 0.4,
          child: const SizedBox(
            width: 62,
            height: 62,
            child: Center(child: BackBadge()),
          ),
        ),
      ),
    );
  }
}

/// What the theme hands every AppBar back button. The AppBar's IconButton
/// squeezes its icon into ~40px, so the badge is laid out in a 24px slot and
/// allowed to paint past it (OverflowBox) at full size; the IconButton's own
/// 48px tap target stays in place underneath.
class AppBarBackBadge extends StatelessWidget {
  const AppBarBackBadge({super.key});

  @override
  Widget build(BuildContext context) {
    return const SizedBox(
      width: 24,
      height: 24,
      child: OverflowBox(
        maxWidth: 60,
        maxHeight: 60,
        child: BackBadge(contained: true),
      ),
    );
  }
}
