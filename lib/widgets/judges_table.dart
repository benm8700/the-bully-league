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
    required this.playerColors,
    this.localViewBuilder,
    this.activeSeatUid,
  });

  final List<JudgeSeat> seats;

  /// The seat uid currently speaking (loudest), when known - gets the spotlight
  /// in the 5-up layout. Null falls back to the head judge, then the first seat.
  final int? activeSeatUid;

  /// Remote judge seat uids currently publishing video.
  final Set<int> present;

  /// judgeId -> display name, for the tile label.
  final Map<String, String> judgeNames;

  /// playerId -> display name, for the "voted for X" badge + the tally.
  final Map<String, String> playerNames;

  /// playerId -> the battler's "stage gel" colour (player 1 red, player 2 blue).
  /// A judge's vote wraps their tile in the colour of the battler they picked.
  final Map<String, Color> playerColors;

  /// Builds a remote judge's video tile by their seat uid.
  final Widget? Function(int seatUid) remoteViewBuilder;

  /// Builds the viewing judge's own camera tile (null for the crowd).
  final Widget? Function()? localViewBuilder;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Expanded(
          child: seats.length >= 5 ? _spotlight(context) : _grid(context),
        ),
        _tallyBar(context),
      ],
    );
  }

  /// A full panel (5+) does NOT fit as equal tiles on a phone, so it is shown
  /// broadcast-style: the current speaker big up top, everyone else in a small
  /// strip below. All faces stay on screen, and the big tile follows whoever is
  /// talking (falls back to the head judge, then the first seat).
  Widget _spotlight(BuildContext context) {
    final big = _spotlightSeat();
    final rest = [for (final s in seats) if (s.seatUid != big.seatUid) s];
    return Padding(
      padding: const EdgeInsets.all(4),
      child: Column(
        children: [
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: _seatTile(context, big),
            ),
          ),
          SizedBox(
            height: 96,
            child: Row(
              children: [
                for (final s in rest)
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.all(4),
                      child: _seatTile(context, s),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  JudgeSeat _spotlightSeat() {
    if (activeSeatUid != null) {
      for (final s in seats) {
        if (s.seatUid == activeSeatUid) return s;
      }
    }
    for (final s in seats) {
      if (s.isHead) return s;
    }
    return seats.first;
  }

  /// A small panel (<=4) fits as equal tiles - and 2 side-by-side is the sweet
  /// spot on a phone. Rows fill the height equally, max two per row (so three
  /// is 2-over-1, never a cramped 3-across).
  Widget _grid(BuildContext context) {
    if (seats.isEmpty) return const SizedBox.shrink();
    final rows = _rowSizes(seats.length);
    var i = 0;
    final rowWidgets = <Widget>[];
    for (final count in rows) {
      final tiles = <Widget>[];
      for (var c = 0; c < count; c++) {
        tiles.add(Expanded(
          child: Padding(
            padding: const EdgeInsets.all(4),
            child: _seatTile(context, seats[i++]),
          ),
        ));
      }
      rowWidgets.add(Expanded(child: Row(children: tiles)));
    }
    return Padding(
      padding: const EdgeInsets.all(4),
      child: Column(children: rowWidgets),
    );
  }

  /// Tiles per row for a small panel: 1-2 in one row, 3 as 2-over-1, 4 as 2+2.
  static List<int> _rowSizes(int n) {
    if (n <= 2) return [n];
    if (n == 3) return [2, 1];
    return [2, 2];
  }

  Widget _seatTile(BuildContext context, JudgeSeat s) {
    Widget? video;
    if (s.isMe) {
      video = localViewBuilder?.call();
    } else if (present.contains(s.seatUid)) {
      video = remoteViewBuilder(s.seatUid);
    }
    final name = judgeNames[s.judgeId] ?? 'Judge';
    // The vote, the instant it lands: the whole tile is wrapped in the colour
    // of the battler this judge picked (player 1 red, player 2 blue). Glanceable
    // - the panel's lean reads as a red/blue split without reading any names.
    final voteColor = s.votedFor == null ? null : playerColors[s.votedFor];
    return AnimatedContainer(
      duration: const Duration(milliseconds: 250),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border:
            voteColor == null ? null : Border.all(color: voteColor, width: 4),
        boxShadow: voteColor == null
            ? null
            : [BoxShadow(color: voteColor.withValues(alpha: 0.55), blurRadius: 14)],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(voteColor == null ? 12 : 9),
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
                  child:
                      _pill(context, '\u{1F451} Head', context.palette.reward),
                ),
              if (s.votedFor != null && voteColor != null)
                Positioned(
                  top: 6,
                  right: 6,
                  child: _pill(
                      context, playerNames[s.votedFor] ?? 'picked', voteColor),
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
                        color: playerColors[players[i]] ??
                            context.palette.winner,
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
