import 'package:flutter/material.dart';

import '../../core/badges/badges.dart';
import 'badge_art.dart';

/// The awards case shown on the profile: every badge, earned in colour and
/// locked ones greyed with their criteria, tiered badges showing progress to
/// the next tier.
///
/// ORDERED BY IMPORTANCE (prestige, highest first) so the rarest awards lead
/// and the everyone-gets-them ones (Contender, Road Dog) sit at the end - the
/// tournament Champion trophy is the very first tile (developer's call,
/// 2026-10-07). This is display ordering, NOT a competing status ladder (the
/// one-status rule is about a rival rank/title progression; a showcase of
/// achievements sorted by rarity is not that).
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
    // EARNED first (best -> worst), then the locked/greyed ones (best -> worst)
    // - so what you've won leads, top-left, and the chase sits after it
    // (developer's call, 2026-10-17). Within each group, higher prestige wins.
    final slots = [...badgeSlots(stats, earnedIds)]..sort((a, b) {
        if (a.earned != b.earned) return a.earned ? -1 : 1;
        return b.def.prestige.compareTo(a.def.prestige);
      });
    final earnedCount = slots.where((s) => s.earned).length;

    // Two rows, scrolling sideways: each "column" is two tiles stacked, so a
    // phone shows ~3 columns (6 badges) and you swipe right for the rest.
    final columns = <List<BadgeSlot>>[];
    for (var i = 0; i < slots.length; i += 2) {
      columns.add(slots.sublist(i, (i + 2).clamp(0, slots.length)));
    }

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
            const Spacer(),
            if (columns.length > 3)
              Row(children: [
                Text('swipe',
                    style: text.bodySmall
                        ?.copyWith(color: const Color(0xFF6E6A78))),
                const Icon(Icons.chevron_right,
                    size: 16, color: Color(0xFF6E6A78)),
              ]),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          'Milestones you earn as you play and vote.',
          style: text.bodySmall?.copyWith(color: const Color(0xFF9A96A2)),
        ),
        const SizedBox(height: 14),
        SizedBox(
          height: _tileHeight * 2 + 16, // two rows + the gap between them
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: EdgeInsets.zero,
            itemCount: columns.length,
            separatorBuilder: (_, _) => const SizedBox(width: 8),
            itemBuilder: (context, c) {
              final col = columns[c];
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _BadgeTile(slot: col[0]),
                  const SizedBox(height: 16),
                  if (col.length > 1)
                    _BadgeTile(slot: col[1])
                  else
                    const SizedBox(width: _tileWidth, height: _tileHeight),
                ],
              );
            },
          ),
        ),
      ],
    );
  }
}

const double _tileWidth = 104;
const double _tileHeight = 116;

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
      width: _tileWidth,
      height: _tileHeight,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          BadgeArt(def: def, earned: slot.earned, size: 58),
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
