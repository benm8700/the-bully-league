import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';

/// The shared Home mode button - Play, Watch, Main Stage.
///
/// All three boxes are the SAME size, centred down the middle, with the icon +
/// word centred inside. A [badge] (Main Stage's COMING SOON) drops over the
/// middle as a pop-up; a [footer] (Play's 2x line) rides along the TOP edge on
/// its own, without shifting the centred word.
///
/// Finish (2026-10-30): a proper glossy-glass button - a depth gradient body, a
/// top gloss reflection + inner edge highlight, a soft bottom shadow, a richer
/// icon glow and a tight lit edge, so these read as tactile buttons rather than
/// flat neon outlines. The known-good "icon tile beside the label" version is
/// preserved at commit 4e9e3fb.
class HomeActionCard extends StatelessWidget {
  const HomeActionCard({
    super.key,
    required this.label,
    required this.icon,
    required this.onTap,
    required this.accent,
    required this.accentEnd,
    this.subtitle,
    this.badge,
    this.footer,
    this.enabled = true,
    this.onInfo,
  });

  /// The big button word, e.g. "PLAY". Use "\n" to stack (Main Stage).
  final String label;

  /// The glowing icon inside the box (use [neonIcon]).
  final Widget icon;

  final VoidCallback onTap;

  /// The mode's primary neon colour - the gradient start, the icon, the label.
  final Color accent;

  /// The box border's cooler second colour.
  final Color accentEnd;

  /// A small description line along the BOTTOM of the box (Play's "Roast a
  /// stranger", Watch's line), in the display serif. Fits inside without
  /// changing the box or word size.
  final String? subtitle;

  /// An optional pop-up pill dropped over the middle of the box (Main Stage's
  /// COMING SOON), with a dim scrim behind it.
  final Widget? badge;

  /// An optional small line along the top of the box (Play's 2x line).
  final Widget? footer;

  /// When false the box can't be tapped (Main Stage while COMING SOON).
  final bool enabled;

  /// When set, a small "?" in the top-right corner opens a brief explainer.
  final VoidCallback? onInfo;

  static const double _radius = 24;
  static const double _border = 2.2;

  /// One shared size for all three boxes, so they're equal.
  static const double _boxWidth = 288;
  static const double _boxHeight = 116;

  /// A big glowing Material icon for the box - a tight core glow plus a soft
  /// wide halo, so it reads as a lit element rather than a flat glyph.
  static Widget neonIcon(IconData icon, Color color) => Icon(
        icon,
        color: color,
        size: 48,
        shadows: [
          Shadow(color: color, blurRadius: 10),
          Shadow(color: color.withValues(alpha: 0.6), blurRadius: 24),
        ],
      );

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final labelStyle = TextStyle(
      fontFamily: p.display,
      color: accent,
      fontSize: 33,
      letterSpacing: 0.5,
      height: 1.02,
      fontVariations: [
        const FontVariation('wght', 700),
        FontVariation('wdth', p.displayWidth),
        const FontVariation('opsz', 33),
      ],
      shadows: [
        Shadow(color: accent.withValues(alpha: 0.5), blurRadius: 12),
      ],
    );

    // Centred icon + word.
    final content = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          icon,
          const SizedBox(width: 16),
          Flexible(
            child: Text(
              label,
              style: labelStyle,
              maxLines: 2,
              textAlign: TextAlign.center,
            ),
          ),
        ],
      ),
    );

    final box = DecoratedBox(
      // Two-tone outer glow: a tight lit edge hugging the border, plus a soft
      // ambient halo. Outside the ClipRRect so it isn't cut off.
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(_radius),
        boxShadow: [
          BoxShadow(
              color: accent.withValues(alpha: 0.50),
              blurRadius: 11,
              spreadRadius: 0),
          BoxShadow(
              color: accentEnd.withValues(alpha: 0.24),
              blurRadius: 26,
              spreadRadius: 1),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(_radius),
        child: Stack(
          alignment: Alignment.center,
          children: [
            // 1. The gradient ring fills the whole box (the neon border).
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [accent, accentEnd],
                  ),
                ),
              ),
            ),
            // 2. The glassy interior, inset by the border - a vertical depth
            // gradient (lighter top, darker base) the background shows through.
            Positioned.fill(
              child: Padding(
                padding: const EdgeInsets.all(_border),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(_radius - _border),
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.black.withValues(alpha: 0.56),
                        Colors.black.withValues(alpha: 0.82),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            // 3. A soft shadow pooling at the base, so the body has depth.
            Positioned(
              bottom: _border,
              left: _border,
              right: _border,
              height: _boxHeight * 0.42,
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.vertical(
                        bottom: Radius.circular(_radius - _border)),
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.transparent,
                        Colors.black.withValues(alpha: 0.30),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            // 4. The top gloss - a glass reflection falling off down the body.
            Positioned(
              top: _border,
              left: _border,
              right: _border,
              height: _boxHeight * 0.46,
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.vertical(
                        top: Radius.circular(_radius - _border)),
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.white.withValues(alpha: 0.13),
                        Colors.white.withValues(alpha: 0.0),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            // 5. A crisp hairline glint along the top inner edge (glass rim).
            Positioned(
              top: _border + 2,
              left: _border + 16,
              right: _border + 16,
              height: 1.6,
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.26),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
            ),
            content,
            // The footer (Play's 2x line) rides along the TOP on its own, so the
            // centred icon + word are never pushed off the icon's line.
            if (footer != null)
              Positioned(
                top: 11,
                left: 0,
                right: 0,
                child: Align(alignment: Alignment.center, child: footer!),
              ),
            // The description sits along the BOTTOM on its own (display serif),
            // so it fits inside without touching the centred icon + word.
            if (subtitle != null)
              Positioned(
                left: 14,
                right: 14,
                bottom: 9,
                child: IgnorePointer(
                  child: Text(
                    subtitle!,
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: p.display,
                      color: Colors.white.withValues(alpha: 0.76),
                      fontSize: 11.5,
                      height: 1.12,
                      letterSpacing: 0.1,
                      fontVariations: [
                        const FontVariation('wght', 540),
                        FontVariation('wdth', p.displayWidth),
                        const FontVariation('opsz', 11.5),
                      ],
                    ),
                  ),
                ),
              ),
            // COMING SOON pop-up: a dim scrim over the interior + the pill
            // centred on top, so it covers the whole button.
            if (badge != null) ...[
              Positioned.fill(
                child: IgnorePointer(
                  child: Padding(
                    padding: const EdgeInsets.all(_border),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.5),
                        borderRadius: BorderRadius.circular(_radius - _border),
                      ),
                    ),
                  ),
                ),
              ),
              IgnorePointer(child: badge!),
            ],
            // Whole-box ripple + tap, clipped to the rounded box, tinted to the
            // mode colour so a press feels on-brand.
            Positioned.fill(
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  // Disabled (onTap null) while COMING SOON, so the box can't be
                  // pressed - no ripple, no navigation.
                  onTap: enabled ? onTap : null,
                  splashColor: accent.withValues(alpha: 0.18),
                  highlightColor: accent.withValues(alpha: 0.10),
                ),
              ),
            ),
            // A "?" in the top-right corner (above the main ripple, so its tap
            // is captured separately) opens a brief explainer. Works even when
            // the box itself is disabled (Main Stage). Deliberately big and
            // glowing in the mode's colour so people WANT to tap it - the
            // explainer is how a new player learns the mode.
            if (onInfo != null)
              Positioned(
                top: 3,
                right: 3,
                child: Material(
                  color: Colors.transparent,
                  shape: const CircleBorder(),
                  child: InkWell(
                    customBorder: const CircleBorder(),
                    onTap: onInfo,
                    child: Padding(
                      padding: const EdgeInsets.all(6),
                      child: Container(
                        width: 27,
                        height: 27,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: accent.withValues(alpha: 0.24),
                          border: Border.all(
                            color: accent.withValues(alpha: 0.95),
                            width: 1.4,
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: accent.withValues(alpha: 0.45),
                              blurRadius: 8,
                            ),
                          ],
                        ),
                        child: const Text(
                          '?',
                          style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w800,
                            fontSize: 16,
                            height: 1.0,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );

    // Centre a shared-size box so all three match and stack down the middle.
    return Align(
      alignment: Alignment.center,
      child: SizedBox(width: _boxWidth, height: _boxHeight, child: box),
    );
  }
}

/// The Main Stage gold, reused for the aspirational callout in a mode dialog.
const Color _kGold = Color(0xFFF8C73B);

/// A brief "what is this mode" dialog, used by the Home boxes' "?" buttons.
///
/// [highlight], when set, renders as an eye-catching callout beneath the body -
/// the Main Stage "prizes and fame" hook on the Play dialog (gold by default),
/// or the judges'-table hook on the Judge dialog. [highlightColor] tints it
/// (defaults to gold); [highlightLinkText] + [onHighlightTap] make a word
/// inside it a clickable link (which also closes the dialog first).
void showModeInfo(
  BuildContext context, {
  required String title,
  required String body,
  required Color accent,
  String? highlight,
  Color? highlightColor,
  String? highlightLinkText,
  VoidCallback? onHighlightTap,
}) {
  final p = context.palette;
  showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: const Color(0xFF191320),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(color: accent.withValues(alpha: 0.5), width: 1),
      ),
      title: Text(
        title,
        style: TextStyle(
          fontFamily: p.display,
          color: accent,
          fontSize: 22,
          fontVariations: [
            const FontVariation('wght', 680),
            FontVariation('wdth', p.displayWidth),
            const FontVariation('opsz', 22),
          ],
        ),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            body,
            style: const TextStyle(
                color: Colors.white70, height: 1.4, fontSize: 14.5),
          ),
          if (highlight != null) ...[
            const SizedBox(height: 16),
            _HighlightCallout(
              text: highlight,
              color: highlightColor ?? _kGold,
              linkText: highlightLinkText,
              onTap: onHighlightTap == null
                  ? null
                  : () {
                      Navigator.of(ctx).pop();
                      onHighlightTap();
                    },
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: Text('Got it',
              style: TextStyle(color: accent, fontWeight: FontWeight.w700)),
        ),
      ],
    ),
  );
}

/// The aspirational callout inside a mode dialog: a tinted box with a trophy
/// and a line of text, optionally with one word turned into a brighter,
/// underlined link. Owns its tap recogniser so it is disposed cleanly.
class _HighlightCallout extends StatefulWidget {
  const _HighlightCallout({
    required this.text,
    required this.color,
    this.linkText,
    this.onTap,
  });

  final String text;
  final Color color;
  final String? linkText;
  final VoidCallback? onTap;

  @override
  State<_HighlightCallout> createState() => _HighlightCalloutState();
}

class _HighlightCalloutState extends State<_HighlightCallout> {
  TapGestureRecognizer? _recognizer;

  @override
  void initState() {
    super.initState();
    if (widget.linkText != null && widget.onTap != null) {
      _recognizer = TapGestureRecognizer()..onTap = widget.onTap;
    }
  }

  @override
  void dispose() {
    _recognizer?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.color;
    final baseStyle = TextStyle(
      color: color,
      fontWeight: FontWeight.w700,
      height: 1.3,
      fontSize: 13.5,
    );

    final link = widget.linkText;
    final idx = link == null ? -1 : widget.text.indexOf(link);
    final Widget textWidget;
    if (link != null && idx >= 0 && _recognizer != null) {
      // The link word is brighter (lerped toward white) and underlined, so it
      // reads as tappable against the rest of the callout.
      final linkColor = Color.lerp(color, Colors.white, 0.4)!;
      textWidget = Text.rich(
        TextSpan(
          style: baseStyle,
          children: [
            TextSpan(text: widget.text.substring(0, idx)),
            TextSpan(
              text: link,
              style: TextStyle(
                color: linkColor,
                fontWeight: FontWeight.w900,
                decoration: TextDecoration.underline,
                decorationColor: linkColor,
              ),
              recognizer: _recognizer,
            ),
            TextSpan(text: widget.text.substring(idx + link.length)),
          ],
        ),
      );
    } else {
      textWidget = Text(widget.text, style: baseStyle);
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.45)),
      ),
      child: Row(
        children: [
          Icon(Icons.emoji_events, color: color, size: 20),
          const SizedBox(width: 10),
          Expanded(child: textWidget),
        ],
      ),
    );
  }
}
