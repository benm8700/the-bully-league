import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// THE NEON NOTE (developer, 2026-11-18: the little on-video notices "look
/// really bad"). The small-notice sibling of NeonDialog: a dark glass card in
/// a thin gradient ring with a soft glow, a round icon badge, a display-font
/// headline and one plain line under it. For status notices that sit over a
/// video (the Judge result, "still being decided"), not for anything that
/// asks a question - that is NeonDialog.
class NeonNote extends StatelessWidget {
  const NeonNote({
    super.key,
    required this.title,
    this.message,
    this.icon = Icons.check_rounded,
    this.accent = judgeGreen,
    this.accentEnd = neonBlue,
    this.child,
  });

  final String title;
  final String? message;
  final IconData icon;
  final Color accent;
  final Color accentEnd;

  /// Optional extra content under the message (e.g. the live tally).
  final Widget? child;

  static const judgeGreen = Color(0xFF2EE59D);
  static const neonBlue = Color(0xFF3D7BFF);
  static const pink = Color(0xFFFF2E7E);
  static const gold = Color(0xFFF8C73B);

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Container(
      constraints: const BoxConstraints(maxWidth: 320),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [accent, accentEnd],
        ),
        boxShadow: [
          BoxShadow(color: accent.withValues(alpha: 0.35), blurRadius: 18),
          BoxShadow(color: Colors.black.withValues(alpha: 0.5), blurRadius: 12),
        ],
      ),
      padding: const EdgeInsets.all(1.5),
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 12, 18, 12),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18.5),
          gradient: const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xF21C1226), Color(0xF20B0911)],
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 30,
                  height: 30,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: accent.withValues(alpha: 0.16),
                    border: Border.all(
                      color: accent.withValues(alpha: 0.8),
                      width: 1.2,
                    ),
                  ),
                  child: Icon(icon, size: 17, color: accent),
                ),
                const SizedBox(width: 12),
                Flexible(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title.toUpperCase(),
                        style: TextStyle(
                          fontFamily: p.display,
                          fontSize: 15,
                          letterSpacing: 0.9,
                          color: Colors.white,
                          fontVariations: [
                            const FontVariation('wght', 800),
                            FontVariation('wdth', p.displayWidth),
                          ],
                        ),
                      ),
                      if (message != null) ...[
                        const SizedBox(height: 2),
                        Text(
                          message!,
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.72),
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
            if (child != null) ...[const SizedBox(height: 10), child!],
          ],
        ),
      ),
    );
  }
}
