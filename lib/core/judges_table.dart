// Pure logic for the Main Stage judges' video table: mapping the seated panel
// to stable seat positions / Agora uids, and folding in each judge's live vote.
// Kept out of the widget so it can be unit-tested without a device.
//
// Mirrors the server: a judge at panel index i publishes on the judges channel
// with Agora uid `seatUidBase + i` (JUDGE_SEAT_UID_BASE in spectator.js), so
// both the judges and the crowd render each seat at a fixed position.

/// The seat-uid base, mirroring JUDGE_SEAT_UID_BASE in functions/spectator.js.
/// The crowd learns it from watchJudgesTable; a publishing judge (who uses the
/// publisher-token path, not watchJudgesTable) reads it from here.
const int kJudgeSeatUidBase = 11;

class JudgeSeat {
  const JudgeSeat({
    required this.seatIndex,
    required this.seatUid,
    required this.judgeId,
    required this.isHead,
    required this.isMe,
    this.votedFor,
  });

  final int seatIndex;

  /// The Agora uid this judge publishes with (seatUidBase + seatIndex).
  final int seatUid;
  final String judgeId;

  /// The head judge (founder) - breaks ties, marked on the table.
  final bool isHead;

  /// This seat is the viewing judge (render their local camera, not a remote).
  final bool isMe;

  /// The player id this judge has voted for, or null until they vote. The vote
  /// is public and lands live, so this drives the badge on the tile.
  final String? votedFor;
}

/// Builds the seat list from the panel. [votes] maps judgeId -> the player id
/// they voted for (from matches/{id}/mainStageVotes, readable by everyone).
List<JudgeSeat> buildJudgeSeats({
  required List<String> panel,
  String? headJudge,
  String? myUid,
  required int seatUidBase,
  Map<String, String> votes = const {},
}) {
  final seats = <JudgeSeat>[];
  for (var i = 0; i < panel.length; i++) {
    final judgeId = panel[i];
    seats.add(JudgeSeat(
      seatIndex: i,
      seatUid: seatUidBase + i,
      judgeId: judgeId,
      isHead: judgeId == headJudge,
      isMe: myUid != null && judgeId == myUid,
      votedFor: votes[judgeId],
    ));
  }
  return seats;
}

/// A running count of judge votes per player id (only counts votes cast).
Map<String, int> judgeVoteTally(Map<String, String> votes) {
  final tally = <String, int>{};
  for (final playerId in votes.values) {
    tally[playerId] = (tally[playerId] ?? 0) + 1;
  }
  return tally;
}
