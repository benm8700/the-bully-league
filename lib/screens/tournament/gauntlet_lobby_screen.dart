import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import '../../widgets/home_action_button.dart';
import '../../widgets/home/rank_badges.dart';
import '../profile/performer_profile_screen.dart';
import 'gauntlet_chat.dart';
import 'gauntlet_watch.dart';

/// The Daily Gauntlet LOBBY: a whole-event "green room".
///
/// Everyone in tonight's gauntlet (and anyone watching) gathers here between
/// battles - see who turned up, tap into their profile, and talk in one shared,
/// live chat. The chat is EPHEMERAL: it's wiped the moment the gauntlet ends
/// (server-side, onGauntletEnded), so a night's banter never outlives the
/// night. Every message is moderated + rate-limited server-side before it
/// appears, and any message can be reported (long-press) into the review queue.
class GauntletLobbyScreen extends StatelessWidget {
  const GauntletLobbyScreen({
    super.key,
    required this.tournamentId,
    this.name,
  });

  final String tournamentId;
  final String? name;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(name == null ? 'Lobby' : '$name · Lobby'),
        actions: const [HomeActionButton()],
      ),
      // A command centre for everyone waiting (the eliminated, the between-
      // battles, the spectators): the live status up top - time left, how many
      // battles are on, who's still in, who's out - and the shared chat below,
      // open throughout so people who've already gone can keep talking.
      body: Column(
        children: [
          _CommandHeader(tournamentId: tournamentId, name: name),
          _Roster(tournamentId: tournamentId),
          const Divider(height: 1),
          Expanded(child: GauntletChat(tournamentId: tournamentId)),
        ],
      ),
    );
  }
}

/// The command-centre status strip: time left in the window, how many battles
/// are live, who's still in, who's knocked out, and a tap into the live
/// battles to watch. Ticks every 30s so the countdown stays current.
class _CommandHeader extends StatefulWidget {
  const _CommandHeader({required this.tournamentId, this.name});

  final String tournamentId;
  final String? name;

  @override
  State<_CommandHeader> createState() => _CommandHeaderState();
}

class _CommandHeaderState extends State<_CommandHeader> {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 30), (_) {
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
    final scheme = Theme.of(context).colorScheme;
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection('tournaments')
          .doc(widget.tournamentId)
          .snapshots(),
      builder: (context, snap) {
        final data = snap.data?.data();
        final climbers = ((data?['climb'] as Map<String, dynamic>?)?['climbers']
                as List?) ??
            const [];
        final s = GauntletState.fromClimbers(climbers);
        final endMs = (data?['windowEndMs'] as num?)?.toInt();
        final minsLeft = endMs == null
            ? null
            : ((endMs - DateTime.now().millisecondsSinceEpoch) / 60000).ceil();
        final showCountdown =
            minsLeft != null && minsLeft > 0 && minsLeft < 24 * 60;
        return Container(
          margin: const EdgeInsets.fromLTRB(12, 12, 12, 4),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.name ?? 'Daily Gauntlet',
                      style: Theme.of(context)
                          .textTheme
                          .titleSmall
                          ?.copyWith(fontWeight: FontWeight.w800),
                    ),
                  ),
                  if (showCountdown)
                    Row(mainAxisSize: MainAxisSize.min, children: [
                      Icon(Icons.timer_outlined,
                          size: 15, color: context.palette.live),
                      const SizedBox(width: 4),
                      Text('${minsLeft}m left',
                          style: Theme.of(context).textTheme.labelMedium?.copyWith(
                              color: context.palette.live,
                              fontWeight: FontWeight.w700)),
                    ]),
                ],
              ),
              const SizedBox(height: 10),
              Row(children: [
                _stat(context, s.liveMatches.length,
                    s.liveMatches.length == 1 ? 'battle on' : 'battles on',
                    context.palette.live),
                _stat(context, s.alive, 'still in', context.palette.reward),
                _stat(context, s.eliminated, 'knocked out',
                    scheme.onSurfaceVariant),
              ]),
              if (s.liveMatches.isNotEmpty)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => GauntletWatchScreen(
                          tournamentId: widget.tournamentId,
                          name: widget.name,
                        ),
                      ),
                    ),
                    icon: Icon(Icons.sensors,
                        size: 16, color: context.palette.live),
                    label: const Text('Watch the live battles'),
                    style: TextButton.styleFrom(
                      padding:
                          const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      minimumSize: const Size(0, 30),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _stat(BuildContext context, int value, String label, Color color) {
    return Expanded(
      child: Column(children: [
        Text('$value',
            style: Theme.of(context)
                .textTheme
                .titleLarge
                ?.copyWith(fontWeight: FontWeight.w800, color: color)),
        Text(label,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant),
            textAlign: TextAlign.center),
      ]),
    );
  }
}

/// "Who's in tonight" - a horizontal strip of the gauntlet's climbers. Tap a
/// card to open their profile. Read live off the tournament doc's climbers.
class _Roster extends StatelessWidget {
  const _Roster({required this.tournamentId});

  final String tournamentId;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection('tournaments')
          .doc(tournamentId)
          .snapshots(),
      builder: (context, snapshot) {
        final climbers = ((snapshot.data?.data()?['climb']
                as Map<String, dynamic>?)?['climbers'] as List?) ??
            const [];
        final uids = <String>[];
        for (final raw in climbers) {
          final uid = (raw as Map)['uid'] as String?;
          if (uid != null) uids.add(uid);
        }
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                uids.isEmpty
                    ? 'Nobody in the gauntlet yet'
                    : "Who's in tonight · ${uids.length}",
                style: Theme.of(context)
                    .textTheme
                    .labelLarge
                    ?.copyWith(fontWeight: FontWeight.w700),
              ),
              if (uids.isNotEmpty) ...[
                const SizedBox(height: 10),
                SizedBox(
                  height: 78,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: uids.length,
                    separatorBuilder: (_, _) => const SizedBox(width: 14),
                    itemBuilder: (_, i) => _RosterChip(uid: uids[i]),
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

class _RosterChip extends StatelessWidget {
  const _RosterChip({required this.uid});

  final String uid;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance.collection('users').doc(uid).snapshots(),
      builder: (context, snap) {
        final u = snap.data?.data();
        final username = u?['username'] as String? ?? 'Roaster';
        final rankTitle = u?['rankTitle'] as String?;
        return InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () =>
              PerformerProfileScreen.open(context, uid, username: username),
          child: SizedBox(
            width: 64,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (rankTitle != null)
                  RankBadge(title: rankTitle, size: 42)
                else
                  const Icon(Icons.person, size: 42),
                const SizedBox(height: 4),
                Text(
                  username,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

