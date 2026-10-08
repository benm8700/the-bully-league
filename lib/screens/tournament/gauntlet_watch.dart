import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import '../../widgets/home_action_button.dart';
import 'gauntlet_chat.dart';
import 'live_viewer_screen.dart';

/// Shared "watch the gauntlet" pieces: the live tournament pulse, the list of
/// battles happening right now, and a standalone screen that puts both together
/// so anyone - not just a waiting climber - can jump straight into judging.
///
/// All of it reads the tournament document's `climb.climbers` directly (no
/// extra callable), so it costs one listener and updates live.

/// A reading of the climbers array: who is battling, who is still in, who is
/// out. Pure, so the counts are obvious and testable.
class GauntletState {
  const GauntletState({
    required this.entrants,
    required this.alive,
    required this.eliminated,
    required this.battling,
    required this.waiting,
    required this.liveMatches,
  });

  final int entrants;
  final int alive; // still in it (not eliminated)
  final int eliminated;
  final int battling; // climbers currently in a match
  final int waiting; // alive but between battles
  /// matchId -> win tier of that battle (both climbers share a win count).
  final Map<String, int> liveMatches;

  factory GauntletState.fromClimbers(List climbers) {
    var eliminated = 0;
    var battling = 0;
    var waiting = 0;
    final live = <String, int>{};
    for (final raw in climbers) {
      final c = raw as Map;
      final status = c['status'] as String?;
      final wins = (c['wins'] as num?)?.toInt() ?? 0;
      if (status == 'eliminated') {
        eliminated++;
      } else if (status == 'in_match') {
        battling++;
        final m = c['currentMatchId'] as String?;
        if (m != null) live[m] = wins;
      } else {
        waiting++;
      }
    }
    return GauntletState(
      entrants: climbers.length,
      alive: climbers.length - eliminated,
      eliminated: eliminated,
      battling: battling,
      waiting: waiting,
      liveMatches: live,
    );
  }
}

List _climbersOf(DocumentSnapshot<Map<String, dynamic>>? snap) {
  return ((snap?.data()?['climb'] as Map<String, dynamic>?)?['climbers']
          as List?) ??
      const [];
}

/// The live tournament pulse: how many battles are on right now, how many
/// roasters are still in it, and how many have been knocked out - the sense of
/// a live crowd moving around you.
class GauntletPulse extends StatelessWidget {
  const GauntletPulse({super.key, required this.tournamentId});

  final String tournamentId;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection('tournaments')
          .doc(tournamentId)
          .snapshots(),
      builder: (context, snapshot) {
        final climbers = _climbersOf(snapshot.data);
        if (climbers.isEmpty) return const SizedBox.shrink();
        final s = GauntletState.fromClimbers(climbers);
        final text = Theme.of(context).textTheme;
        final scheme = Theme.of(context).colorScheme;
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(16),
            border:
                Border.all(color: scheme.outlineVariant.withValues(alpha: 0.4)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                  '${s.entrants} ${s.entrants == 1 ? 'roaster' : 'roasters'} in tonight',
                  style:
                      text.labelLarge?.copyWith(fontWeight: FontWeight.w700)),
              const SizedBox(height: 12),
              Row(
                children: [
                  _PulseStat(
                    value: s.liveMatches.length,
                    label: s.liveMatches.length == 1 ? 'battle on' : 'battles on',
                    color: context.palette.live,
                    icon: Icons.sensors,
                  ),
                  _PulseStat(
                    value: s.alive,
                    label: 'still in',
                    color: context.palette.reward,
                    icon: Icons.local_fire_department,
                  ),
                  _PulseStat(
                    value: s.eliminated,
                    label: 'knocked out',
                    color: scheme.onSurfaceVariant,
                    icon: Icons.do_not_disturb_on_outlined,
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}

class _PulseStat extends StatelessWidget {
  const _PulseStat({
    required this.value,
    required this.label,
    required this.color,
    required this.icon,
  });

  final int value;
  final String label;
  final Color color;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Expanded(
      child: Column(
        children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(height: 4),
          Text('$value',
              style: text.headlineSmall
                  ?.copyWith(fontWeight: FontWeight.w800, color: color)),
          Text(label,
              style: text.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant),
              textAlign: TextAlign.center),
        ],
      ),
    );
  }
}

/// The live climb battles happening right now. Each row names the win tier of
/// that battle, so the higher the number the deeper into the gauntlet. Tapping
/// opens the live viewer to watch and vote.
///
/// [excludeUid] hides the viewer's own battle when a climber is watching while
/// they wait; pass null (a pure spectator/judge) to see every live battle.
class GauntletWatchList extends StatelessWidget {
  const GauntletWatchList({
    super.key,
    required this.tournamentId,
    this.excludeUid,
    this.emptyText = 'No other battles live this second - hang tight.',
  });

  final String tournamentId;
  final String? excludeUid;
  final String emptyText;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection('tournaments')
          .doc(tournamentId)
          .snapshots(),
      builder: (context, snapshot) {
        final climbers = _climbersOf(snapshot.data);
        final matches = <String, int>{};
        for (final raw in climbers) {
          final c = raw as Map;
          if (excludeUid != null && c['uid'] == excludeUid) continue;
          if (c['status'] != 'in_match') continue;
          final m = c['currentMatchId'] as String?;
          if (m == null) continue;
          matches[m] = (c['wins'] as num?)?.toInt() ?? 0;
        }
        if (matches.isEmpty) {
          return Text(emptyText,
              style: Theme.of(context).textTheme.bodySmall);
        }
        final entries = matches.entries.toList()
          ..sort((a, b) => b.value.compareTo(a.value)); // deepest tier first
        return Column(
          children: [
            for (final e in entries)
              _WatchRow(matchId: e.key, winTier: e.value),
          ],
        );
      },
    );
  }
}

/// One battle in the judge list. Streams the match so a just-finished battle
/// flips from "Battling now" to "Vote now - Xm left" and stays in the list
/// through its whole vote window, instead of vanishing the moment it ends.
class _WatchRow extends StatefulWidget {
  const _WatchRow({required this.matchId, required this.winTier});

  final String matchId;
  final int winTier;

  @override
  State<_WatchRow> createState() => _WatchRowState();
}

class _WatchRowState extends State<_WatchRow> {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    // Keeps the "Xm left" fresh - the match doc itself doesn't change during
    // the vote window, so the stream alone would never update the countdown.
    _ticker = Timer.periodic(const Duration(seconds: 15), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tier = widget.winTier == 0 ? 'Opening battle' : '${widget.winTier}-win battle';
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection('matches')
          .doc(widget.matchId)
          .snapshots(),
      builder: (context, snap) {
        final m = snap.data?.data();
        final completed = m?['status'] == 'completed';
        final finalized = m?['voteFinalized'] == true;
        int? minsLeft;
        if (completed && m != null) {
          final comp = m['completedAt'];
          final vw = m['voteWindowMs'];
          if (comp is Timestamp && vw is num) {
            final end = comp.millisecondsSinceEpoch + vw.toInt();
            minsLeft =
                ((end - DateTime.now().millisecondsSinceEpoch) / 60000).ceil();
          }
        }
        final voteNow =
            completed && !finalized && (minsLeft == null || minsLeft > 0);
        final live = context.palette.live;
        final reward = context.palette.reward;
        return Card(
          child: ListTile(
            leading: Icon(voteNow ? Icons.how_to_vote : Icons.sensors,
                color: voteNow ? reward : live),
            title: Text(tier,
                style: const TextStyle(fontWeight: FontWeight.bold)),
            subtitle: Text(voteNow
                ? (minsLeft != null && minsLeft > 0
                    ? 'Vote now · ${minsLeft}m left'
                    : 'Vote now')
                : 'Battling now · watch'),
            trailing: voteNow
                ? _VoteNowTag(color: reward)
                : const Icon(Icons.play_arrow),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => LiveViewerScreen(matchId: widget.matchId),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _VoteNowTag extends StatelessWidget {
  const _VoteNowTag({required this.color});
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text('VOTE',
          style: TextStyle(
              color: color, fontWeight: FontWeight.w800, fontSize: 11)),
    );
  }
}

/// Jump-straight-to-judging screen for the gauntlet: the pulse plus every live
/// battle to watch and vote on. Reached from the tournament screen's "Judge
/// live battles" button, so a spectator never has to enter the gauntlet (or
/// finish a match) just to find something to judge.
class GauntletWatchScreen extends StatelessWidget {
  const GauntletWatchScreen({
    super.key,
    required this.tournamentId,
    this.name,
  });

  final String tournamentId;
  final String? name;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final myUid = FirebaseAuth.instance.currentUser?.uid;
    return Scaffold(
      appBar: AppBar(
        title: Text(name == null ? 'Judge the Gauntlet' : 'Judge: $name'),
        actions: const [HomeActionButton()],
      ),
      // Command centre: the live status + battles up top, the lobby chat
      // below so the room keeps talking the whole event.
      body: Column(
        children: [
          Expanded(
            flex: 5,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              children: [
                GauntletPulse(tournamentId: tournamentId),
                const SizedBox(height: 18),
                Text('Live now - watch and vote', style: text.titleMedium),
                const SizedBox(height: 4),
                Text('Judging earns you points, and the crowd decides.',
                    style: text.bodySmall),
                const SizedBox(height: 10),
                GauntletWatchList(
                  tournamentId: tournamentId,
                  excludeUid: myUid,
                  emptyText: 'No battles live right now. '
                      'Check back in a minute - the gauntlet is rolling.',
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Row(
              children: [
                const Icon(Icons.forum_outlined, size: 16),
                const SizedBox(width: 6),
                Text('Lobby chat', style: text.titleSmall),
              ],
            ),
          ),
          Expanded(flex: 6, child: GauntletChat(tournamentId: tournamentId)),
        ],
      ),
    );
  }
}

/// A compact "Tournament LIVE - Judge now" pill meant to be overlaid at the
/// top of the Judge feed. It shows ONLY while a gauntlet battle is actually
/// live (a live battle's 90s window closes long before a clip could reach the
/// feed, so this is the only timely way to surface tournament judging where
/// everyone already is). Tapping opens the live judging list. Renders nothing
/// when no gauntlet battle is on.
class GauntletLivePill extends StatelessWidget {
  const GauntletLivePill({super.key});

  @override
  Widget build(BuildContext context) {
    final myUid = FirebaseAuth.instance.currentUser?.uid;
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection('tournaments')
          .where('status', isEqualTo: 'in_progress')
          .snapshots(),
      builder: (context, snapshot) {
        String? tournamentId;
        String name = 'Daily Gauntlet';
        var liveCount = 0;
        for (final doc in snapshot.data?.docs ?? const []) {
          final t = doc.data();
          if (t['format'] != 'climb') continue;
          final climbers =
              ((t['climb'] as Map<String, dynamic>?)?['climbers'] as List?) ??
                  const [];
          final seen = <String>{};
          for (final raw in climbers) {
            final c = raw as Map;
            if (c['status'] != 'in_match') continue;
            if (c['uid'] == myUid) continue;
            final m = c['currentMatchId'] as String?;
            if (m == null || !seen.add(m)) continue;
            liveCount++;
            tournamentId = doc.id;
            name = t['name'] as String? ?? name;
          }
        }
        if (tournamentId == null || liveCount == 0) {
          return const SizedBox.shrink();
        }
        final live = context.palette.live;
        return Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(20),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => GauntletWatchScreen(
                  tournamentId: tournamentId!,
                  name: name,
                ),
              ),
            ),
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.55),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: live, width: 1.5),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.sensors, size: 16, color: live),
                  const SizedBox(width: 6),
                  Text(
                    'Tournament LIVE · '
                    '$liveCount ${liveCount == 1 ? 'battle' : 'battles'} · Judge now',
                    style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                        fontSize: 12.5),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
