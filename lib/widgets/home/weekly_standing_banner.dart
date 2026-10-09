import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../../screens/leaderboard/leaderboard_screen.dart';
import '../../theme/app_theme.dart';

/// The companion to the WEEKLY Ranks board: a one-line personal hook under the
/// tournament banner telling you where you stand in this week's qualifier race
/// and how close the top-4 Main Stage cutoff is - the thing that makes you play
/// one more match. Taps straight through to the WEEKLY board. The full
/// standings live in Ranks; this is just the "how close am I?" nudge.
///
/// Renders NOTHING unless there's a live weekly race (the flag is off until
/// launch, so stats/weeklyQualifier has no standings), so Home stays clean.
class WeeklyStandingBanner extends StatefulWidget {
  const WeeklyStandingBanner({super.key});

  @override
  State<WeeklyStandingBanner> createState() => _WeeklyStandingBannerState();
}

/// Must match FINALISTS in weeklyTournament.js / the WEEKLY board.
const int _cutoff = 4;

class _WeeklyStandingBannerState extends State<WeeklyStandingBanner> {
  bool _loaded = false;
  int? _position; // 1-based position in the standings, null if not listed
  bool _hasRace = false;

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
      final standings = (doc.data()?['standings'] as List?) ?? const [];
      final uid = FirebaseAuth.instance.currentUser?.uid;
      int? pos;
      for (var i = 0; i < standings.length; i++) {
        final e = standings[i];
        if (e is Map && e['uid'] == uid) {
          pos = i + 1;
          break;
        }
      }
      if (!mounted) return;
      setState(() {
        _hasRace = standings.isNotEmpty;
        _position = pos;
        _loaded = true;
      });
    } catch (_) {
      if (mounted) setState(() => _loaded = true);
    }
  }

  ({String line, IconData icon, bool strong})? _copy() {
    if (!_hasRace) return null; // no active race -> render nothing
    final p = _position;
    if (p == null) {
      return (
        line: "This week's race is on — climb into the top $_cutoff.",
        icon: Icons.trending_up,
        strong: false,
      );
    }
    if (p <= _cutoff) {
      return (
        line: "You're #$p this week — in the top $_cutoff. Hold it.",
        icon: Icons.emoji_events,
        strong: true,
      );
    }
    if (p <= _cutoff * 2) {
      return (
        line: "You're #$p — just outside the top $_cutoff. Keep climbing.",
        icon: Icons.trending_up,
        strong: true,
      );
    }
    return (
      line: "You're #$p this week. Climb toward the top $_cutoff.",
      icon: Icons.trending_up,
      strong: false,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) return const SizedBox.shrink();
    final c = _copy();
    if (c == null) return const SizedBox.shrink();
    final gold = context.palette.reward;
    final strong = c.strong;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Material(
        color: gold.withValues(alpha: strong ? 0.16 : 0.08),
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => const LeaderboardScreen(initialTab: 3),
            ),
          ),
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: gold.withValues(alpha: strong ? 0.45 : 0.22),
              ),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                Icon(c.icon, size: 18, color: gold),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    c.line,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          fontWeight:
                              strong ? FontWeight.w700 : FontWeight.w500,
                        ),
                  ),
                ),
                Icon(Icons.chevron_right,
                    size: 18, color: gold.withValues(alpha: 0.8)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
