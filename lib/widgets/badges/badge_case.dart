import 'package:flutter/material.dart';

import '../../core/badges/badges.dart';
import 'badge_art.dart';

/// The awards case shown on the profile: every badge, earned in colour and
/// locked ones greyed with their criteria, tiered badges showing progress to
/// the next tier. Achievements only - never an ordered ladder (one-status
/// rule), so there is no ranking or sorting-by-strength here.
///
/// There is no "feature/pin" mechanism (removed 2026-09-29, developer's call):
/// badges are just displayed, not pinned.
class BadgeCase extends StatelessWidget {
  const BadgeCase({
    super.key,
    required this.stats,
    required this.earnedIds,
  });

  final BadgeStats stats;
  final Set<String> earnedIds;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final slots = badgeSlots(stats, earnedIds);
    final earnedCount = slots.where((s) => s.earned).length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('Awards', style: text.titleMedium),
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
          'Milestones you earn as you play and judge.',
          style: text.bodySmall?.copyWith(color: const Color(0xFF9A96A2)),
        ),
        const SizedBox(height: 14),
        Wrap(
          spacing: 8,
          runSpacing: 16,
          children: [
            for (final s in slots) _BadgeTile(slot: s),
          ],
        ),
      ],
    );
  }
}

class _BadgeTile extends StatelessWidget {
  const _BadgeTile({required this.slot});

  final BadgeSlot slot;

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
      sub = 'Earned';
    } else {
      sub = def.lockedHint;
    }

    return SizedBox(
      width: 104,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          BadgeArt(def: def, earned: slot.earned, size: 62),
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
              color: slot.earned
                  ? const Color(0xFFB8B4C0)
                  : const Color(0xFF6E6A78),
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}
