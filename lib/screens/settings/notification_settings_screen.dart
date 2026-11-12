import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

/// Per-category notification toggles.
///
/// Deliberately not one global on/off switch: a single switch is the one
/// that gets turned off permanently after one annoying notification, taking
/// the genuinely useful alerts with it. Someone who doesn't want vote
/// reminders almost certainly still wants to know an opponent is waiting,
/// and giving them that choice here is what stops them taking the blunter
/// option of muting the whole app at the OS level - which nothing in the
/// app can undo or even detect.
///
/// Absent preferences mean opted IN, matching the server (see
/// functions/notifications.js). Existing accounts have no preferences map
/// at all, and treating that as opted-out would silently switch
/// notifications off for the entire userbase.
class NotificationSettingsScreen extends StatelessWidget {
  const NotificationSettingsScreen({super.key});

  /// Ordered most-useful first, so the one people actually want is the one
  /// they see before they start switching things off.
  static const _categories = <_Category>[
    _Category(
      key: 'match_found',
      icon: Icons.bolt_rounded,
      accent: Color(0xFFFF2E7E),
      title: 'Opponent found',
      description:
          'When someone is matched with you. Turning this off means you '
          'will only find out by opening the app.',
    ),
    _Category(
      key: 'event_window',
      icon: Icons.local_bar_rounded,
      accent: Color(0xFFF8C73B),
      title: 'Happy Hour',
      description:
          'When the daily prime-time hour starts, and a last call '
          'before it ends.',
    ),
    _Category(
      key: 'vote_reminder',
      icon: Icons.gavel_rounded,
      accent: Color(0xFF2FE0A8),
      title: 'Battles waiting for your vote',
      description:
          'Nudges to vote on open battles while their window '
          'is still open.',
    ),
    _Category(
      key: 'tournament',
      icon: Icons.emoji_events_rounded,
      accent: Color(0xFFF8C73B),
      title: 'Tournaments',
      description: 'Bracket starts, your next round, and results.',
    ),
    _Category(
      key: 'main_stage',
      icon: Icons.theater_comedy_rounded,
      accent: Color(0xFFB45CFF),
      title: 'The Main Stage',
      description:
          'When the weekly finals go live, when your battle is up, '
          'and when a battle needs your verdict.',
    ),
    _Category(
      key: 'followed_performer',
      icon: Icons.mic_rounded,
      accent: Color(0xFFFF2E7E),
      title: 'Comedians you follow',
      description:
          'When someone you follow is performing, or drops '
          'a new clip.',
    ),
    _Category(
      key: 'rank_change',
      icon: Icons.trending_up_rounded,
      accent: Color(0xFF3D7BFF),
      title: 'Rank changes',
      description: 'When you move up or down a rank.',
    ),
    _Category(
      key: 'weekly_recap',
      icon: Icons.calendar_month_rounded,
      accent: Color(0xFF3D7BFF),
      title: 'Weekly recap',
      description: 'A Sunday summary of what you did this week.',
    ),
    _Category(
      key: 'daily_reward',
      icon: Icons.redeem_rounded,
      accent: Color(0xFFF8C73B),
      title: 'Daily reward',
      description:
          'An evening nudge if you have not claimed your free daily '
          'reward before the day resets.',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      return const Scaffold(body: Center(child: Text('Not signed in.')));
    }
    final userRef = FirebaseFirestore.instance.collection('users').doc(uid);

    return Scaffold(
      appBar: AppBar(title: const Text('Notifications')),
      body: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
        stream: userRef.snapshots(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          final prefs =
              (snapshot.data?.data()?['notificationPrefs'] as Map?) ?? const {};

          final bottom = MediaQuery.of(context).viewPadding.bottom;
          return ListView(
            padding: EdgeInsets.fromLTRB(16, 8, 16, 24 + bottom),
            children: [
              for (final category in _categories)
                _PrefCard(
                  category: category,
                  on: prefs[category.key] != false,
                  onChanged: (value) => userRef.set({
                    'notificationPrefs': {category.key: value},
                  }, SetOptions(merge: true)),
                ),
              const Padding(
                padding: EdgeInsets.fromLTRB(4, 12, 4, 0),
                child: Text(
                  'Turning everything off here is better than blocking the '
                  'app in your phone settings - if you do that, we can\'t '
                  'turn anything back on for you.',
                  style: TextStyle(fontSize: 12, color: Colors.white54),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _Category {
  const _Category({
    required this.key,
    required this.title,
    required this.description,
    required this.icon,
    required this.accent,
  });

  final String key;
  final IconData icon;
  final Color accent;
  final String title;
  final String description;
}

/// One notification type as a glass card (2026-11-11 neon pass): a glowing
/// icon tile in the category's colour, the title and description, and the
/// neon switch. The whole card lights up (border + glow) while it is ON, and
/// the whole card is tappable, not just the switch.
class _PrefCard extends StatelessWidget {
  const _PrefCard({
    required this.category,
    required this.on,
    required this.onChanged,
  });

  final _Category category;
  final bool on;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final accent = category.accent;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              on ? accent.withValues(alpha: 0.12) : const Color(0xFF15111C),
              const Color(0xFF0C0A12),
            ],
          ),
          border: Border.all(
            color: on
                ? accent.withValues(alpha: 0.55)
                : Colors.white.withValues(alpha: 0.08),
            width: 1.3,
          ),
          boxShadow: on
              ? [
                  BoxShadow(
                    color: accent.withValues(alpha: 0.18),
                    blurRadius: 14,
                  ),
                ]
              : null,
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(18),
            onTap: () => onChanged(!on),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 4, 8),
              child: Row(
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(10),
                      color: accent.withValues(alpha: on ? 0.16 : 0.06),
                      border: Border.all(
                        color: accent.withValues(alpha: on ? 0.5 : 0.15),
                      ),
                    ),
                    child: Icon(
                      category.icon,
                      size: 20,
                      color: on ? accent : accent.withValues(alpha: 0.4),
                      shadows: on
                          ? [Shadow(color: accent, blurRadius: 10)]
                          : null,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          category.title,
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                            color: on ? Colors.white : Colors.white60,
                          ),
                        ),
                        const SizedBox(height: 1),
                        Text(
                          category.description,
                          style: TextStyle(
                            fontSize: 12,
                            height: 1.25,
                            color: Colors.white.withValues(
                              alpha: on ? 0.6 : 0.4,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 6),
                  Transform.scale(
                    scale: 0.85,
                    child: Switch(value: on, onChanged: onChanged),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
