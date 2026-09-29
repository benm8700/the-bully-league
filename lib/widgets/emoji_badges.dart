import 'package:flutter/material.dart';

import '../core/emoji_ratings.dart';

/// "Crowd badges" - the badges of honour a player earns from the audience
/// emojis (🔥 Fire and 🧠 Clever). Rendered as glyph medals: the emoji itself
/// sits in a gold medallion when earned, dimmed with its threshold when not.
///
/// These use no art files - the emoji IS the emblem - so they ship without
/// waiting on illustrated crests (real PNG art could replace the glyph later).
///
/// GUARDRAIL (one-status-ladder): these are ACHIEVEMENTS, not a rank. They mark
/// "the crowd loved you N times", never "you rank above Y", and never appear on
/// a board. They live on the profile beside the Crowd read card.
class EmojiBadges extends StatelessWidget {
  const EmojiBadges({
    super.key,
    required this.counts,
    this.ownProfile = true,
  });

  /// The user document's emojiCounts map (may be null/partial).
  final Map<String, dynamic>? counts;

  /// On your own profile every track shows (earned in gold, locked with the
  /// threshold to chase). On someone else's, only EARNED honours show - a
  /// stranger's locked progress means nothing - and the whole section hides
  /// when they have earned none.
  final bool ownProfile;

  static const _gold = Color(0xFFF4C838);

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    var slots = emojiBadgeSlots(counts);
    if (!ownProfile) slots = slots.where((s) => s.earned).toList();
    if (slots.isEmpty) return const SizedBox.shrink();

    final earnedCount = slots.where((s) => s.earned).length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('Crowd badges', style: text.titleMedium),
            if (ownProfile) ...[
              const SizedBox(width: 8),
              Text(
                '$earnedCount / ${slots.length}',
                style: text.bodySmall?.copyWith(
                  color: const Color(0xFF9A96A2),
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: 4),
        Text(
          ownProfile
              ? 'Earn these off the \u{1F525} and \u{1F9E0} the crowd throws you.'
              : 'Honours earned from the crowd.',
          style: text.bodySmall?.copyWith(color: const Color(0xFF9A96A2)),
        ),
        const SizedBox(height: 14),
        Wrap(
          spacing: 8,
          runSpacing: 16,
          children: [for (final s in slots) _EmojiMedalTile(slot: s)],
        ),
      ],
    );
  }
}

class _EmojiMedalTile extends StatelessWidget {
  const _EmojiMedalTile({required this.slot});

  final EmojiBadgeSlot slot;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final tier = slot.displayTier;

    // Sub-line: earned + more to come = progress to the next tier; earned +
    // maxed = top tier; locked = the count to reach the first tier.
    final String sub;
    if (slot.earned && !slot.isMaxed) {
      sub = '${slot.count} / ${slot.nextTier!.at}';
    } else if (slot.earned) {
      sub = 'Top tier';
    } else {
      sub = 'Earn at ${tier.at}';
    }

    return SizedBox(
      width: 104,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _EmojiMedal(emoji: slot.emoji, earned: slot.earned, size: 62),
          const SizedBox(height: 6),
          Text(
            tier.title,
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
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: text.bodySmall?.copyWith(
              fontSize: 11,
              color: slot.isMaxed && slot.earned
                  ? EmojiBadges._gold
                  : slot.earned
                      ? const Color(0xFFB8B4C0)
                      : const Color(0xFF6E6A78),
              fontWeight:
                  slot.isMaxed && slot.earned ? FontWeight.w700 : FontWeight.w400,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

/// The medallion: the emoji glyph in a gold-rimmed disc when earned, dimmed and
/// grey-rimmed when not. Mirrors the drawn medallion in badge_art.dart so glyph
/// badges and illustrated badges read as one system.
class _EmojiMedal extends StatelessWidget {
  const _EmojiMedal({
    required this.emoji,
    required this.earned,
    this.size = 62,
  });

  final String emoji;
  final bool earned;
  final double size;

  @override
  Widget build(BuildContext context) {
    const gold = EmojiBadges._gold;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: const RadialGradient(
          center: Alignment(-0.3, -0.4),
          radius: 0.95,
          colors: [Color(0xFF3A2F14), Color(0xFF1A1508)],
        ),
        border: Border.all(
          color: earned ? gold.withValues(alpha: 0.85) : Colors.white.withValues(alpha: 0.14),
          width: 2,
        ),
        boxShadow: earned
            ? [BoxShadow(color: gold.withValues(alpha: 0.30), blurRadius: 10)]
            : null,
      ),
      child: Center(
        child: Opacity(
          opacity: earned ? 1 : 0.3,
          child: Text(emoji, style: TextStyle(fontSize: size * 0.42)),
        ),
      ),
    );
  }
}
