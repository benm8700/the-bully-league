import 'package:flutter/material.dart';

/// One way to battle, presented as a single tappable option card.
///
/// Both Home battle modes - "Roast a Stranger" (now) and tonight's tournament -
/// render through this one shell so they read as two options of the SAME kind
/// rather than two unrelated boxes. Only the accent colour, the copy and the
/// [status] line differ; the shape, size and anatomy are identical.
///
/// The WHOLE card is the tap target (a chevron is the affordance) - there is no
/// button nested inside a tappable card, which was the redundancy the old
/// layout had. Anything that is a genuinely different action (the "?" explainer,
/// the "I'm in tonight" pre-commit) goes in [trailing] or [footer], not as a
/// second primary button competing with the card's own tap.
class BattleModeCard extends StatelessWidget {
  const BattleModeCard({
    super.key,
    required this.accent,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.status,
    required this.onTap,
    this.trailing,
    this.footer,
  });

  /// The mode's colour - pink for "now", gold for the prize event. Tints the
  /// icon, the title and the status so colour does the work of telling the two
  /// modes apart.
  final Color accent;
  final IconData icon;
  final String title;

  /// One plain line saying what the mode is.
  final String subtitle;

  /// The differentiator line, built by the caller and styled in [accent]:
  /// a live countdown for the tournament, "Play now" for Roast a Stranger.
  final Widget status;

  final VoidCallback onTap;

  /// A small secondary control pinned top-right (e.g. the "?" explainer).
  final Widget? trailing;

  /// A quiet secondary row under a divider (e.g. the "I'm in tonight"
  /// pre-commit). Kept visually distinct from the card's own tap so it does
  /// not read as a second button.
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: scheme.surfaceContainerHighest,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 8, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Icon(icon, color: accent, size: 24),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: text.titleMedium?.copyWith(
                            color: accent,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          subtitle,
                          style: text.bodySmall
                              ?.copyWith(color: scheme.onSurfaceVariant),
                        ),
                        const SizedBox(height: 6),
                        status,
                      ],
                    ),
                  ),
                  if (trailing != null) trailing!,
                  Icon(Icons.chevron_right, color: scheme.onSurfaceVariant),
                ],
              ),
              if (footer != null) ...[
                const SizedBox(height: 12),
                Divider(
                    height: 1,
                    thickness: 1,
                    color: scheme.outlineVariant.withValues(alpha: 0.4)),
                const SizedBox(height: 10),
                footer!,
              ],
            ],
          ),
        ),
      ),
    );
  }
}
