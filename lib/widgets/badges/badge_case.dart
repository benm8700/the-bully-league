import 'package:flutter/material.dart';

import '../../core/badges/badges.dart';
import 'badge_art.dart';

/// The badge case shown on the profile: every badge, earned in colour and
/// locked ones greyed with their criteria, tiered badges showing progress to
/// the next tier. Achievements only - never an ordered ladder (one-status
/// rule), so there is no ranking or sorting-by-strength here.
///
/// Tapping an EARNED badge pins it as the featured badge (via [onFeature]); the
/// currently featured one is marked.
class BadgeCase extends StatelessWidget {
  const BadgeCase({
    super.key,
    required this.stats,
    required this.earnedIds,
    this.featuredId,
    this.onFeature,
  });

  final BadgeStats stats;
  final Set<String> earnedIds;
  final String? featuredId;
  final ValueChanged<String>? onFeature;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final slots = badgeSlots(stats, earnedIds);
    final earnedCount = slots.where((s) => s.earned).length;
    final resolvedFeatured = featuredBadge({
      'badges': {'earned': earnedIds.toList(), 'featured': featuredId},
    })?.id;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('Badges', style: text.titleMedium),
            const SizedBox(width: 8),
            Text(
              '$earnedCount / ${slots.length}',
              style: text.bodySmall?.copyWith(
                color: const Color(0xFF9A96A2),
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          onFeature != null && earnedCount > 0
              ? 'Tap an earned badge to feature it on your profile.'
              : 'Milestones you earn as you play and judge.',
          style: text.bodySmall?.copyWith(color: const Color(0xFF9A96A2)),
        ),
        const SizedBox(height: 14),
        Wrap(
          spacing: 8,
          runSpacing: 16,
          children: [
            for (final s in slots)
              _BadgeTile(
                slot: s,
                isFeatured: s.earned && s.def.id == resolvedFeatured,
                onTap: (s.earned && onFeature != null)
                    ? () => onFeature!(s.def.id)
                    : null,
              ),
          ],
        ),
      ],
    );
  }
}

class _BadgeTile extends StatelessWidget {
  const _BadgeTile({required this.slot, required this.isFeatured, this.onTap});

  final BadgeSlot slot;
  final bool isFeatured;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final def = slot.def;

    // Sub-line: a family badge with a next tier shows numeric progress; an
    // earned single says so; a locked single shows how to earn it.
    final String sub;
    if (def.family != null && !slot.isMaxed) {
      sub = '${slot.current} / ${slot.goal}';
    } else if (slot.earned) {
      sub = isFeatured ? 'Featured' : 'Earned';
    } else {
      sub = def.lockedHint;
    }

    return SizedBox(
      width: 104,
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Stack(
              clipBehavior: Clip.none,
              children: [
                BadgeArt(def: def, earned: slot.earned, size: 62),
                if (isFeatured)
                  const Positioned(
                    right: -2,
                    top: -2,
                    child: Icon(Icons.push_pin,
                        size: 16, color: Color(0xFFF4C838)),
                  ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              def.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: text.labelMedium?.copyWith(
                fontWeight: FontWeight.w700,
                color: slot.earned ? Colors.white : const Color(0xFF7C7887),
              ),
            ),
            const SizedBox(height: 2),
            Text(
              sub,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: text.bodySmall?.copyWith(
                fontSize: 11,
                color: isFeatured
                    ? const Color(0xFFF4C838)
                    : slot.earned
                        ? const Color(0xFFB8B4C0)
                        : const Color(0xFF6E6A78),
                fontWeight: isFeatured ? FontWeight.w700 : FontWeight.w400,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
