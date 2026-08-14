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
    required this.videoUrl,
    required this.verdict,
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
  final String? videoUrl;

  /// Null while voting is open. Populated once settled, and revealed only
  /// after the clip has played - showing the winner above an unwatched
  /// video spoils it.
  final FeedVerdict? verdict;

  static FeedMatch fromMap(Map<String, dynamic> m) => FeedMatch(
        matchId: m['matchId'] as String,
        player1Id: m['player1Id'] as String? ?? '',
        player2Id: m['player2Id'] as String? ?? '',
        player1Username: m['player1Username'] as String? ?? 'Player 1',
        player2Username: m['player2Username'] as String? ?? 'Player 2',
        voteCount: (m['voteCount'] as num?)?.toInt() ?? 0,
        canVote: m['canVote'] == true,
        isParticipant: m['isParticipant'] == true,
        videoUrl: m['videoUrl'] as String?,
        verdict: FeedVerdict.fromMap(m['verdict']),
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
  const WatchFeedPage({required this.matches, required this.pendingVotes});

  final List<FeedMatch> matches;

  /// How many battles are waiting on this viewer, for the Judge tab badge.
  final int pendingVotes;
}

/// Talks to the feed and the vote session.
///
/// Voting goes through a SESSION rather than a CAPTCHA per ballot: one
/// solve buys a bounded run, because a checkbox between every video would
/// make judging a chore and votes are the scarce resource here. See
/// functions/voteSession.js.
class WatchFeedService {
  Future<WatchFeedPage> fetch({int limit = 10}) async {
    final result = await FirebaseFunctions.instance
        .httpsCallable('getWatchFeed')
        .call<Map<String, dynamic>>({'limit': limit});
    final raw = (result.data['matches'] as List?) ?? const [];
    return WatchFeedPage(
      matches: raw
          .map((e) => FeedMatch.fromMap((e as Map).cast<String, dynamic>()))
          .toList(),
      pendingVotes: (result.data['pendingVotes'] as num?)?.toInt() ?? 0,
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

  Future<void> castVote({
    required String matchId,
    required String votedForPlayerId,
    String? turnstileToken,
  }) async {
    await FirebaseFunctions.instance.httpsCallable('castVote').call({
      'matchId': matchId,
      'votedForPlayerId': votedForPlayerId,
      // ignore: use_null_aware_elements
      if (turnstileToken != null) 'turnstileToken': turnstileToken,
    });
  }
}
