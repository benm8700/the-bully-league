import 'package:flutter/material.dart';

import '../core/judges_table.dart';
import '../theme/app_theme.dart';

/// The Main Stage judges' video table: the seated panel on camera, each tile
/// labelled with the judge, the head judge marked, and - the point of it -
/// every judge's REAL vote landing live and public on their tile as they cast
/// it, with a running tally underneath.
///
/// Presentational: the caller computes [seats] (buildJudgeSeats) from the panel
/// + the live votes, supplies the live [present] remote uids, and the video
/// builders. Both the judge's room (which supplies a local camera tile) and the
/// crowd's viewer (no local tile) render with this same widget.
class JudgesTable extends StatelessWidget {
  const JudgesTable({
    super.key,
    required this.seats,
    required this.present,
    required this.judgeNames,
    required this.playerNames,
    required this.remoteViewBuilder,
    this.localViewBuilder,
  });

  final List<JudgeSeat> seats;

  /// Remote judge seat uids currently publishing video.
  final Set<int> present;

  /// judgeId -> display name, for the tile label.
  final Map<String, String> judgeNames;

  /// playerId -> display name, for the "voted for X" badge + the tally.
  final Map<String, String> playerNames;

  /// Builds a remote judge's video tile by their seat uid.
  final Widget? Function(int seatUid) remoteViewBuilder;

  /// Builds the viewing judge's own camera tile (null for the crowd).
  final Widget? Function()? localViewBuilder;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Expanded(
          child: GridView.count(
            crossAxisCount: 2,
            childAspectRatio: 0.72,
            padding: const EdgeInsets.all(8),
            mainAxisSpacing: 8,
            crossAxisSpacing: 8,
            children: [for (final s in seats) _seatTile(context, s)],
          ),
        ),
        _tallyBar(context),
      ],
    );
  }

  Widget _seatTile(BuildContext context, JudgeSeat s) {
    Widget? video;
    if (s.isMe) {
      video = localViewBuilder?.call();
    } else if (present.contains(s.seatUid)) {
      video = remoteViewBuilder(s.seatUid);
    }
    final name = judgeNames[s.judgeId] ?? 'Judge';
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: Container(
        color: const Color(0xFF141414),
        child: Stack(
          fit: StackFit.expand,
          children: [
            video ??
                const Center(
                  child: Icon(Icons.videocam_off_outlined,
                      color: Colors.white24, size: 28),
                ),
            if (s.isHead)
              Positioned(
                top: 6,
                left: 6,
                child: _pill(context, '\u{1F451} Head', context.palette.reward),
              ),
            if (s.votedFor != null)
              Positioned(
                top: 6,
                right: 6,
                child: _pill(
                    context,
                    '\u{2192} ${playerNames[s.votedFor] ?? 'picked'}',
                    context.palette.winner),
              ),
            Positioned(
              left: 6,
              right: 6,
              bottom: 6,
              child: Text(
                s.isMe ? '$name (you)' : name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                  shadows: [Shadow(blurRadius: 4, color: Colors.black)],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _pill(BuildContext context, String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.9),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(text,
          style: const TextStyle(
              color: Colors.white, fontSize: 11, fontWeight: FontWeight.w800)),
    );
  }

  Widget _tallyBar(BuildContext context) {
    final votes = <String, String>{
      for (final s in seats)
        if (s.votedFor != null) s.judgeId: s.votedFor!,
    };
    final tally = judgeVoteTally(votes);
    final players = playerNames.keys.toList();
    final cast = votes.length;
    final total = seats.length;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      color: Theme.of(context).colorScheme.surface,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('$cast of $total judges have voted',
              style: Theme.of(context).textTheme.labelMedium),
          const SizedBox(height: 6),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              for (var i = 0; i < players.length; i++) ...[
                if (i > 0) const SizedBox(width: 18),
                Text(
                  '${playerNames[players[i]] ?? ''}  ${tally[players[i]] ?? 0}',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w800,
                        color: context.palette.winner,
                      ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}
