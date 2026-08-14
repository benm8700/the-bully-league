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
      title: 'Opponent found',
      description:
          'When someone is matched with you. Turning this off means you '
          'will only find out by opening the app.',
    ),
    _Category(
      key: 'event_window',
      title: 'Sixes and Sevens',
      description: 'When the daily prime-time hour starts, and a last call '
          'before it ends.',
    ),
    _Category(
      key: 'vote_reminder',
      title: 'Battles waiting to be judged',
      description: 'Nudges to judge open battles while their vote window '
          'is still open.',
    ),
    _Category(
      key: 'tournament',
      title: 'Tournaments',
      description: 'Bracket starts, your next round, and results.',
    ),
    _Category(
      key: 'rank_change',
      title: 'Rank changes',
      description: 'When you move up or down a rank.',
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

          return ListView(
            padding: const EdgeInsets.symmetric(vertical: 8),
            children: [
              for (final category in _categories)
                SwitchListTile(
                  value: prefs[category.key] != false,
                  title: Text(category.title),
                  subtitle: Text(category.description),
                  isThreeLine: true,
                  onChanged: (value) => userRef.set({
                    'notificationPrefs': {category.key: value},
                  }, SetOptions(merge: true)),
                ),
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 16, 16, 24),
                child: Text(
                  'Turning everything off here is better than blocking the '
                  'app in your phone settings - if you do that, we can\'t '
                  'turn anything back on for you.',
                  style: TextStyle(fontSize: 12),
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
  });

  final String key;
  final String title;
  final String description;
}
