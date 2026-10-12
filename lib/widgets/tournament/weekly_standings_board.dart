import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../../screens/profile/performer_profile_screen.dart';
import '../../theme/app_theme.dart';
import '../empty_state.dart';

/// This week's qualifier race toward the Main Stage - the Standings tab of the
/// tournament hub. Reads the server-published board at stats/weeklyQualifier
/// (refreshed every 15 min by the qualifier sweep), ranks by the week's
/// hidden-Elo gain, and draws the top-4 cutoff line so a player can see if
/// they're climbing into the finals. Position-only + battles-this-week - no raw
/// Elo number, same discretion as the skill board. Renders an empty state until
/// the tournament flag is on.
///
/// (Lifted out of the Ranks board's old WEEKLY tab, 2026-10-12 - the weekly
/// race now lives in the tournament hub, not among the skill/fame/applause
/// boards.)
class WeeklyStandingsBoard extends StatefulWidget {
  const WeeklyStandingsBoard({super.key, this.topPad = 8});
  final double topPad;

  @override
  State<WeeklyStandingsBoard> createState() => _WeeklyStandingsBoardState();
}

/// Top 4 go to the Main Stage - must match FINALISTS in weeklyTournament.js.
const int _weeklyCutoff = 4;

class _WeeklyStandingsBoardState extends State<WeeklyStandingsBoard> {
  bool _loading = true;
  List<Map<String, dynamic>> _rows = const [];
  final Map<String, String> _names = {};
  int? _cutoffMs;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final doc = await FirebaseFirestore.instance
          .collection('stats')
          .doc('weeklyQualifier')
          .get();
      final data = doc.data();
      final raw = (data?['standings'] as List?) ?? const [];
      final rows = raw
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .where((e) => e['uid'] is String)
          .take(30)
          .toList();
      // Resolve usernames for the displayed rows in one batched read.
      final uids = rows.map((e) => e['uid'] as String).toList();
      if (uids.isNotEmpty) {
        final q = await FirebaseFirestore.instance
            .collection('users')
            .where(FieldPath.documentId, whereIn: uids)
            .get();
        for (final d in q.docs) {
          final n = d.data()['username'];
          if (n is String) _names[d.id] = n;
        }
      }
      if (!mounted) return;
      setState(() {
        _rows = rows;
        _cutoffMs = (data?['cutoffMs'] as num?)?.toInt();
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  String _timeLeft() {
    final c = _cutoffMs;
    if (c == null) return '';
    final left = c - DateTime.now().millisecondsSinceEpoch;
    if (left <= 0) return 'Qualifying has closed — the field is being set.';
    final h = left ~/ (1000 * 60 * 60);
    if (h >= 48) return 'Qualifying closes in ${h ~/ 24} days.';
    if (h >= 1) return 'Qualifying closes in $h hours.';
    return 'Qualifying closes within the hour.';
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_rows.isEmpty) {
      return Padding(
        padding: EdgeInsets.only(top: widget.topPad),
        child: const EmptyState(
          icon: Icons.emoji_events_outlined,
          title: 'The race starts Thursday night',
          message:
              'Every ranked battle this week moves you up here. The top 4 make '
              'the weekly Main Stage — climb in.',
        ),
      );
    }
    final gold = context.palette.reward;
    final selfUid = FirebaseAuth.instance.currentUser?.uid;
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;

    final children = <Widget>[
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('This week’s race',
                style: text.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800, color: gold)),
            const SizedBox(height: 2),
            Text(
              'Top $_weeklyCutoff make the Main Stage. ${_timeLeft()}',
              style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    ];

    for (var i = 0; i < _rows.length; i++) {
      if (i == _weeklyCutoff) children.add(_cutoffDivider(gold));
      children.add(_row(i, _rows[i], selfUid, gold));
    }

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: EdgeInsets.only(top: widget.topPad, bottom: 24),
        children: children,
      ),
    );
  }

  Widget _cutoffDivider(Color gold) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            Expanded(child: Divider(color: gold.withValues(alpha: 0.5))),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Text('MAIN STAGE CUTOFF',
                  style: TextStyle(
                      color: gold,
                      fontWeight: FontWeight.w900,
                      fontSize: 11,
                      letterSpacing: 1)),
            ),
            Expanded(child: Divider(color: gold.withValues(alpha: 0.5))),
          ],
        ),
      );

  Widget _row(int i, Map<String, dynamic> e, String? selfUid, Color gold) {
    final uid = e['uid'] as String;
    final games = (e['games'] as num?)?.toInt() ?? 0;
    final isSelf = uid == selfUid;
    final inCut = i < _weeklyCutoff;
    final scheme = Theme.of(context).colorScheme;
    final name = _names[uid] ?? 'Roaster';
    return Material(
      color: isSelf ? gold.withValues(alpha: 0.14) : Colors.transparent,
      child: ListTile(
        dense: true,
        visualDensity: const VisualDensity(vertical: -3),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => PerformerProfileScreen(uid: uid),
          ),
        ),
        leading: Text(
          '${i + 1}',
          style: TextStyle(
            fontWeight: FontWeight.w900,
            fontSize: 16,
            color: inCut ? gold : scheme.onSurfaceVariant,
          ),
        ),
        title: Text(
          isSelf ? '$name  (you)' : name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontWeight: isSelf ? FontWeight.w800 : FontWeight.w600,
          ),
        ),
        trailing: Text(
          '$games ${games == 1 ? "battle" : "battles"}',
          style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
        ),
      ),
    );
  }
}
