import 'package:flutter/material.dart';

import '../core/emoji_ratings.dart';

/// "Rate this player": their name plus the four emoji choices, the picked one
/// lit. Shared by every vote surface (the feed panel, the vote-queue screen
/// and the live vote panel) so the rating gesture is identical everywhere.
class EmojiRateRow extends StatelessWidget {
  const EmojiRateRow({
    super.key,
    required this.name,
    required this.selected,
    required this.onSelect,
    this.accent,
    this.dark = true,
  });

  final String name;
  final String? selected;
  final ValueChanged<String> onSelect;
  final Color? accent;

  /// When true (over a video), text is white and the unselected chips are a
  /// faint white. When false (on a light surface), they use theme colours.
  final bool dark;

  @override
  Widget build(BuildContext context) {
    final a = accent ?? Theme.of(context).colorScheme.primary;
    final nameColor = dark ? Colors.white : null;
    final idle = dark
        ? Colors.white.withValues(alpha: 0.08)
        : Theme.of(context).colorScheme.surfaceContainerHighest;
    return Row(
      children: [
        SizedBox(
          width: 88,
          child: Text(
            name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: nameColor, fontSize: 13),
          ),
        ),
        Expanded(
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              for (final r in kEmojiRatings)
                GestureDetector(
                  onTap: () => onSelect(r.key),
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                    decoration: BoxDecoration(
                      color: selected == r.key ? a.withValues(alpha: 0.85) : idle,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(r.emoji, style: const TextStyle(fontSize: 22)),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
