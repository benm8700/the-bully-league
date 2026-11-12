import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import '../neon_dialog.dart';

/// "Win your first ranked battle by the deadline and get \$5."
///
/// Mirrors functions/firstWinReward.js, which is the authority (it decides who
/// is actually paid). This only advertises the offer to someone who could
/// still earn it: the switch is on, the budget isn't spent, they haven't been
/// rewarded, and their 7 days (from account creation, to the minute) aren't up.
/// Renders nothing otherwise.
class FirstWinOfferBanner extends StatelessWidget {
  const FirstWinOfferBanner({super.key, required this.uid, this.onPlayRanked});

  final String uid;
  final VoidCallback? onPlayRanked;

  static const _dayMs = 24 * 60 * 60 * 1000;

  @override
  Widget build(BuildContext context) {
    final db = FirebaseFirestore.instance;
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: db.collection('config').doc('firstWinReward').snapshots(),
      builder: (context, cfgSnap) {
        final cfg = cfgSnap.data?.data();
        if (cfg == null || cfg['enabled'] != true) {
          return const SizedBox.shrink();
        }
        final amount = _num(cfg['amountUsd'], 1, 100, 5);
        final days = _num(cfg['windowDays'], 1, 60, 7);
        final created =
            FirebaseAuth.instance.currentUser?.metadata.creationTime;
        if (created == null) return const SizedBox.shrink();
        final deadline = created.add(Duration(milliseconds: days * _dayMs));
        if (!DateTime.now().isBefore(deadline)) return const SizedBox.shrink();
        return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
          stream: db.collection('stats').doc('firstWinReward').snapshots(),
          builder: (context, statSnap) {
            if (statSnap.data?.data()?['exhausted'] == true) {
              return const SizedBox.shrink();
            }
            return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
              stream: db.collection('users').doc(uid).snapshots(),
              builder: (context, userSnap) {
                if (!userSnap.hasData ||
                    userSnap.data?.data()?['firstWinReward'] != null) {
                  return const SizedBox.shrink();
                }
                return _card(context, amount, deadline);
              },
            );
          },
        );
      },
    );
  }

  static int _num(Object? v, int lo, int hi, int d) {
    final n = (v is num) ? v.toInt() : null;
    return (n != null && n >= lo && n <= hi) ? n : d;
  }

  Widget _card(BuildContext context, int amount, DateTime deadline) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final left = deadline.difference(DateTime.now());
    final leftLabel = left.inDays >= 1
        ? '${left.inDays}d ${left.inHours % 24}h left'
        : '${left.inHours}h ${left.inMinutes % 60}m left';
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Material(
        color: const Color(0xFF14361F),
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onPlayRanked,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
            child: Row(
              children: [
                const Text('💵', style: TextStyle(fontSize: 26)),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Win a ranked battle, get \$$amount',
                        style: text.titleSmall?.copyWith(
                          color: Colors.white,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Finish it by ${_fmt(deadline)} · $leftLabel',
                        style: text.bodySmall?.copyWith(
                          color: Colors.white.withValues(alpha: 0.8),
                        ),
                      ),
                    ],
                  ),
                ),
                TextButton(
                  onPressed: () => _showRules(context, amount, deadline),
                  child: Text(
                    'Rules',
                    style: TextStyle(color: scheme.primaryContainer),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  static String _fmt(DateTime d) {
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    final l = d.toLocal();
    final h = l.hour % 12 == 0 ? 12 : l.hour % 12;
    final m = l.minute.toString().padLeft(2, '0');
    return '${days[l.weekday - 1]} ${months[l.month - 1]} ${l.day}, '
        '$h:$m ${l.hour < 12 ? 'AM' : 'PM'}';
  }

  /// Official rules. Apple guideline 5.3 needs these in the app for any
  /// contest with a prize. DRAFT - have them reviewed before switching this on.
  static Future<void> _showRules(
    BuildContext context,
    int amount,
    DateTime deadline,
  ) {
    return showDialog<void>(
      context: context,
      builder: (ctx) => NeonDialog(
        title: Text('\$$amount first-win rules'),
        content: SingleChildScrollView(
          child: Text(
            '• Win your first ranked battle within 7 days of creating your '
            'account to earn a \$$amount gift card. Your deadline is '
            '${_fmt(deadline)}.\n'
            '• The battle has to be finished before the deadline. The crowd '
            'decides the winner, and the gift card is awarded once voting '
            'closes, even if that is after your deadline.\n'
            '• Only a crowd-judged win counts. A win because your opponent '
            'left does not.\n'
            '• Battles against someone you have challenged or been challenged '
            'by, or who uses the same phone, do not count.\n'
            '• One reward per person and phone number. While the promotion\'s '
            'budget lasts. 18+ only. No purchase necessary.\n'
            '• Claim it in the app with your email. We send it by email.\n'
            '• The Bully League runs this promotion. Apple and Google are not '
            'sponsors and are not involved in any way.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Got it'),
          ),
        ],
      ),
    );
  }
}
