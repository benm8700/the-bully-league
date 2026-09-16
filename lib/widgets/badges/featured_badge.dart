import 'package:flutter/material.dart';

import '../../core/badges/badges.dart';
import 'badge_art.dart';

/// A small chip showing one earned badge - used for the pinned "featured"
/// badge on the profile header and on the pre-match reveal (a bit of identity
/// context for the opponent). Renders nothing when [def] is null.
class FeaturedBadge extends StatelessWidget {
  const FeaturedBadge({super.key, required this.def});

  final BadgeDef? def;

  @override
  Widget build(BuildContext context) {
    final d = def;
    if (d == null) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.fromLTRB(6, 4, 12, 4),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.30),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(
            color: const Color(0xFFF4C838).withValues(alpha: 0.35)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          BadgeArt(def: d, earned: true, size: 26),
          const SizedBox(width: 7),
          Text(
            d.title,
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: const Color(0xFFF4C838),
                  fontWeight: FontWeight.w700,
                ),
          ),
        ],
      ),
    );
  }
}
