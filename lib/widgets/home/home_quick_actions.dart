import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../daily_quests.dart';

/// The Home "Quick Actions" row - three compact cards: Daily Challenges,
/// Free Rewards, Current Streak.
///
/// Styled from design_reference/quick_action_cards_reference.png: a very dark
/// card, a bold accent icon, and a thin accent border with a restrained glow,
/// one accent per feature (pink = Challenges, gold = Rewards, orange = Streak).
///
///  - Daily Challenges opens the real daily quests (the existing
///    `DailyQuests` widget) in a bottom sheet, so the row is a glanceable
///    entry point rather than a second copy of the list.
///  - Current Streak shows the live vote-streak day count from the user
///    document (`voteStreak.days`), rendered as a prominent gold "N DAYS" with
///    a flame that grows more energetic as the streak climbs.
///  - Free Rewards is a PLACEHOLDER (developer's call, 2026-09-14): it is a
///    real backlog feature with no backend yet, so tapping it says as much
///    rather than pretending to work. See CLAUDE.md's backlog for the design.
class HomeQuickActions extends StatelessWidget {
  const HomeQuickActions({super.key, required this.uid});

  final String uid;

  // Accent palette straight from the reference PNG's spec panel.
  static const Color _pink = Color(0xFFFF3B6B); // Challenges
  static const Color _gold = Color(0xFFFFC107); // Rewards + streak value

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Unequal widths: "Daily Challenges" is the longest wording, so
            // it and the streak get a touch more room than Free Rewards.
            Expanded(
              flex: 34,
              child: _QuickCard(
                // Ring with a check breaking through it (the approved
                // reference design) - task_alt, not the solid check_circle.
                icon: Icons.task_alt,
                accent: _pink,
                label: 'Daily\nChallenges',
                onTap: () => _openQuests(context),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              flex: 31,
              child: _QuickCard(
                // Solid wrapped gift box (approved), not the outline card.
                icon: Icons.redeem,
                accent: _gold,
                label: 'Free\nRewards',
                onTap: () => ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Free Rewards is coming soon.'),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              flex: 35,
              child: _StreakCard(uid: uid),
            ),
          ],
        ),
      ),
    );
  }

  void _openQuests(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (_) => const Padding(
        padding: EdgeInsets.fromLTRB(16, 0, 16, 24),
        child: DailyQuests(),
      ),
    );
  }
}

/// The Current Streak card - reads the live streak day count and renders a
/// flame whose energy (colour, size, glow) rises with the streak, plus a
/// prominent gold "N DAYS" value.
class _StreakCard extends StatelessWidget {
  const _StreakCard({required this.uid});

  final String uid;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .snapshots(),
      builder: (context, snapshot) {
        final streak = snapshot.data?.data()?['voteStreak'];
        final days = ((streak is Map ? streak['days'] : null) as num? ?? 0)
            .toInt();
        return _QuickCard(
          icon: Icons.local_fire_department,
          accent: _FlameState.of(days).color,
          label: 'Current Streak',
          flame: _FlameState.of(days),
          value: days > 0 ? '$days ${days == 1 ? 'DAY' : 'DAYS'}' : null,
          onTap: () => ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(days > 0
                  ? 'A $days-day streak. Vote today to keep it alive.'
                  : 'Vote on a battle today to start a streak.'),
            ),
          ),
        );
      },
    );
  }
}

/// How energetic the streak flame looks, by day count - colour, size and glow
/// step up with the streak per the reference's flame-state row.
class _FlameState {
  const _FlameState({
    required this.color,
    required this.size,
    required this.glowAlpha,
    required this.glowBlur,
  });

  final Color color;
  final double size;
  final double glowAlpha;
  final double glowBlur;

  static const Color _streakOrange = Color(0xFFFF5722);

  static _FlameState of(int days) {
    if (days <= 0) {
      // Muted grey flame - no run going.
      return const _FlameState(
        color: Color(0xFF6E6A66),
        size: 22,
        glowAlpha: 0,
        glowBlur: 0,
      );
    }
    if (days <= 2) {
      // Small orange/red active flame.
      return const _FlameState(
        color: _streakOrange,
        size: 22,
        glowAlpha: 0,
        glowBlur: 0,
      );
    }
    if (days <= 4) {
      // Brighter, larger orange.
      return const _FlameState(
        color: Color(0xFFFF6D2A),
        size: 23,
        glowAlpha: 0.22,
        glowBlur: 10,
      );
    }
    if (days <= 6) {
      // Bright orange/yellow with a subtle glow.
      return const _FlameState(
        color: Color(0xFFFF8A1E),
        size: 24,
        glowAlpha: 0.34,
        glowBlur: 13,
      );
    }
    // 7+ : strongest flame, most energy.
    return const _FlameState(
      color: Color(0xFFFFA31E),
      size: 26,
      glowAlpha: 0.46,
      glowBlur: 17,
    );
  }
}

/// One compact quick-action card: a bold accent icon (with an optional glow),
/// an optional prominent gold [value] ("5 DAYS"), and a two-line label.
class _QuickCard extends StatelessWidget {
  const _QuickCard({
    required this.icon,
    required this.accent,
    required this.label,
    required this.onTap,
    this.value,
    this.flame,
  });

  final IconData icon;
  final Color accent;
  final String label;
  final VoidCallback onTap;

  /// A prominent gold value line (the streak day count), shown above the label.
  final String? value;

  /// When set, the icon is a streak flame drawn with this state's glow/size
  /// instead of the plain accent icon.
  final _FlameState? flame;

  static const Color _cardBg = Color(0xFF0E0C12); // very dark navy/black
  static const Color _valueGold = Color(0xFFFFC107);
  static const Color _subtext = Color(0xFFA0A0A0);

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final glowAlpha = flame?.glowAlpha ?? 0.14;
    final glowBlur = flame?.glowBlur ?? 14;
    // Horizontal mini-dashboard card (reference "CARD SIZE IN CONTEXT"):
    // [ icon ] | text  >  - icon left, divider, text, chevron far right.
    return Material(
      color: _cardBg,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: accent.withValues(alpha: 0.55)),
            boxShadow: [
              // Restrained accent glow around the card edge.
              BoxShadow(
                color: accent.withValues(alpha: glowAlpha * 0.6),
                blurRadius: 18,
                spreadRadius: -6,
              ),
            ],
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(6, 9, 6, 9),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Narrow icon area (~26%): a fixed slot so text keeps the rest
                // and the layout stays stable across phone widths. No chevron -
                // the whole card is tappable.
                SizedBox(
                  width: 28,
                  child: Center(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        boxShadow: glowAlpha > 0
                            ? [
                                BoxShadow(
                                  color: accent.withValues(alpha: glowAlpha),
                                  blurRadius: glowBlur,
                                  spreadRadius: 1,
                                ),
                              ]
                            : null,
                      ),
                      child: Icon(icon, color: accent, size: flame?.size ?? 24),
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                // Subtle vertical divider between icon and text.
                Container(
                  width: 1,
                  color: Colors.white.withValues(alpha: 0.14),
                ),
                const SizedBox(width: 7),
                // Text block, vertically centred, left-aligned. Never clips or
                // ellipsizes: a conservative scaleDown keeps every word visible
                // if a narrow width would otherwise crowd it.
                Expanded(child: _buildText(text)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// The card's text, vertically centred and left-aligned.
  ///
  /// - A streak card shows a big gold value ("5 DAYS") over a muted subtitle.
  /// - The other two show a two-line white label ("Daily / Challenges").
  ///
  /// Nothing ever ellipsizes: each text group is wrapped in a scaleDown
  /// FittedBox, so on a narrow card a word shrinks a hair rather than clipping.
  Widget _buildText(TextTheme text) {
    if (value != null) {
      return Align(
        alignment: Alignment.centerLeft,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                value!,
                maxLines: 1,
                softWrap: false,
                style: text.titleSmall?.copyWith(
                  fontSize: 14.5,
                  fontWeight: FontWeight.w900,
                  color: _valueGold,
                  letterSpacing: 0.2,
                  height: 1.0,
                ),
              ),
            ),
            const SizedBox(height: 1),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                label,
                maxLines: 1,
                softWrap: false,
                style: text.labelSmall?.copyWith(
                  fontSize: 9.5,
                  fontWeight: FontWeight.w500,
                  height: 1.0,
                  letterSpacing: 0,
                  color: _subtext,
                ),
              ),
            ),
          ],
        ),
      );
    }
    // Daily / Free: a two-line white label (the '\n' fixes the line break),
    // scaled down conservatively if the card is narrow.
    return Align(
      alignment: Alignment.centerLeft,
      child: FittedBox(
        fit: BoxFit.scaleDown,
        alignment: Alignment.centerLeft,
        child: Text(
          label,
          style: text.labelMedium?.copyWith(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            height: 1.1,
            letterSpacing: 0,
            color: Colors.white,
          ),
        ),
      ),
    );
  }
}
