import 'package:cloud_functions/cloud_functions.dart';

/// One battle in the feed.
class FeedMatch {
  const FeedMatch({
    required this.matchId,
    required this.player1Id,
    required this.player2Id,
    required this.player1Username,
    required this.player2Username,
    required this.voteCount,
    required this.canVote,
    required this.isParticipant,
    required this.alreadyVoted,
    required this.windowOpen,
    required this.videoUrl,
    required this.verdict,
    required this.reactionCounts,
  });

  final String matchId;
  final String player1Id;
  final String player2Id;
  final String player1Username;
  final String player2Username;
  final int voteCount;

  /// True only while this viewer can still cast a REAL ballot: the window
  /// is open, they aren't a participant, and they haven't voted yet.
  /// Everything else is archive - still tappable, but the tap is a private
  /// guess rather than a vote.
  final bool canVote;

  final bool isParticipant;

  /// You judged this one already. Distinct from the archive: voting may
  /// still be open, so there is a live tally rather than a verdict.
  final bool alreadyVoted;

  /// Voting has not closed yet.
  final bool windowOpen;
  final String? videoUrl;

  /// Null while voting is open. Populated once settled, and revealed only
  /// after the clip has played - showing the winner above an unwatched
  /// video spoils it.
  final FeedVerdict? verdict;

  /// Per-emoji tallies as of page load. Not live - a listener per clip in
  /// a scrolling feed is a lot of sockets for a number nobody watches move.
  final Map<String, int> reactionCounts;

  static FeedMatch fromMap(Map<String, dynamic> m) => FeedMatch(
        matchId: m['matchId'] as String,
        player1Id: m['player1Id'] as String? ?? '',
        player2Id: m['player2Id'] as String? ?? '',
        player1Username: m['player1Username'] as String? ?? 'Player 1',
        player2Username: m['player2Username'] as String? ?? 'Player 2',
        voteCount: (m['voteCount'] as num?)?.toInt() ?? 0,
        canVote: m['canVote'] == true,
        isParticipant: m['isParticipant'] == true,
        alreadyVoted: m['alreadyVoted'] == true,
        windowOpen: m['windowOpen'] == true,
        videoUrl: m['videoUrl'] as String?,
        verdict: FeedVerdict.fromMap(m['verdict']),
        reactionCounts: ((m['reactionCounts'] as Map?) ?? const {})
            .map((k, v) => MapEntry(k as String, (v as num).toInt())),
      );
}

class FeedVerdict {
  const FeedVerdict({
    required this.outcome,
    this.winnerId,
    this.player1Share = 0.5,
    this.totalVotes = 0,
  });

  /// 'decided', 'tie', or 'undecided'.
  final String outcome;
  final String? winnerId;
  final double player1Share;
  final int totalVotes;

  static FeedVerdict? fromMap(Object? raw) {
    if (raw is! Map) return null;
    final m = raw.cast<String, dynamic>();
    return FeedVerdict(
      outcome: m['outcome'] as String? ?? 'undecided',
      winnerId: m['winnerId'] as String?,
      player1Share: (m['player1Share'] as num?)?.toDouble() ?? 0.5,
      totalVotes: (m['totalVotes'] as num?)?.toInt() ?? 0,
    );
  }
}

class WatchFeedPage {
  const WatchFeedPage({
    required this.matches,
    required this.pendingVotes,
    required this.nextCursorMs,
  });

  final List<FeedMatch> matches;

  /// How many battles are waiting on this viewer, for the Judge tab badge.
  final int pendingVotes;

  /// Where the next page starts. Null means the archive is exhausted.
  final int? nextCursorMs;
}

/// Talks to the feed and the vote session.
///
/// Voting goes through a SESSION rather than a CAPTCHA per ballot: one
/// solve buys a bounded run, because a checkbox between every video would
/// make judging a chore and votes are the scarce resource here. See
/// functions/voteSession.js.
class WatchFeedService {
  Future<WatchFeedPage> fetch({int limit = 10, int? cursorMs}) async {
    final result = await FirebaseFunctions.instance
        .httpsCallable('getWatchFeed')
        .call<Map<String, dynamic>>({
      'limit': limit,
      // ignore: use_null_aware_elements
      if (cursorMs != null) 'cursorMs': cursorMs,
    });
    final raw = (result.data['matches'] as List?) ?? const [];
    return WatchFeedPage(
      matches: raw
          .map((e) => FeedMatch.fromMap((e as Map).cast<String, dynamic>()))
          .toList(),
      pendingVotes: (result.data['pendingVotes'] as num?)?.toInt() ?? 0,
      nextCursorMs: (result.data['nextCursorMs'] as num?)?.toInt(),
    );
  }

  /// Votes remaining in the current session, so the client can re-challenge
  /// BEFORE a vote is refused rather than after.
  Future<int> sessionVotesRemaining() async {
    try {
      final result = await FirebaseFunctions.instance
          .httpsCallable('getVoteSession')
          .call<Map<String, dynamic>>();
      return result.data['active'] == true
          ? (result.data['votesRemaining'] as num?)?.toInt() ?? 0
          : 0;
    } catch (_) {
      // Treated as "no session", which just means a challenge is shown.
      return 0;
    }
  }

  Future<void> startSession(String turnstileToken) async {
    await FirebaseFunctions.instance
        .httpsCallable('startVoteSession')
        .call<Map<String, dynamic>>({'turnstileToken': turnstileToken});
  }

  /// Records calls on settled battles - private guesses against results
  /// already decided, never ballots.
  ///
  /// Batched because a call happens on every archive clip someone scrolls
  /// past; one invocation per clip would put a function call behind every
  /// swipe. Failures are swallowed by the caller: a lost judge stat is not
  /// worth an error in front of someone watching a video.
  Future<void> recordCalls(List<Map<String, String>> calls) async {
    if (calls.isEmpty) return;
    await FirebaseFunctions.instance
        .httpsCallable('recordJudgeCalls')
        .call<Map<String, dynamic>>({'calls': calls});
  }

  /// Returns the points this vote earned, so the app can show the reward
  /// landing. A bonus nobody notices motivates nobody.
  Future<VoteReward> castVote({
    required String matchId,
    required String votedForPlayerId,
    String? turnstileToken,
  }) async {
    final result = await FirebaseFunctions.instance
        .httpsCallable('castVote')
        .call<Map<String, dynamic>>({
      'matchId': matchId,
      'votedForPlayerId': votedForPlayerId,
      // ignore: use_null_aware_elements
      if (turnstileToken != null) 'turnstileToken': turnstileToken,
    });
    final streak = (result.data['streak'] as Map?)?.cast<String, dynamic>();
    final judge = (result.data['judge'] as Map?)?.cast<String, dynamic>();
    return VoteReward(
      points: (result.data['pointsAwarded'] as num?)?.toInt() ?? 0,
      // Only reported when the streak actually PAID, so a running total
      // is announced once a day rather than after every single vote.
      streakDays: (streak?['awarded'] as num? ?? 0) > 0
          ? (streak?['days'] as num?)?.toInt()
          : null,
      streakPoints: (streak?['awarded'] as num?)?.toInt() ?? 0,
      multiplier: (result.data['pointsMultiplier'] as num?)?.toDouble() ?? 1,
      skipJustEarned: judge?['skipJustEarned'] == true,
      earnedSkips: (judge?['earnedSkips'] as num?)?.toInt() ?? 0,
    );
  }
}

/// What a vote paid, and whether the window bonus was applied.
class VoteReward {
  const VoteReward({
    required this.points,
    required this.multiplier,
    this.streakDays,
    this.streakPoints = 0,
    this.skipJustEarned = false,
    this.earnedSkips = 0,
  });

  final int points;
  final double multiplier;

  /// The run length, but ONLY on the day it was paid - null otherwise, so
  /// the streak is announced once a day rather than on every vote.
  final int? streakDays;
  final int streakPoints;

  /// True for the single vote that crossed the threshold.
  ///
  /// Announced ONCE, at the moment it happens, rather than on every
  /// vote afterwards - the whole reason to surface a reward is that it
  /// changes behaviour, and a line repeated on every vote is one people
  /// stop reading.
  final bool skipJustEarned;

  /// How many skips today's judging has earned in total.
  final int earnedSkips;

  bool get boosted => multiplier > 1;
  bool get extendedStreak => streakDays != null && streakPoints > 0;
}
