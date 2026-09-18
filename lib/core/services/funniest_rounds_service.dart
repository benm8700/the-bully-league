import 'package:cloud_functions/cloud_functions.dart';

/// One entry on the Funniest Rounds board: a battle whose round N was marked
/// funniest by the most judges.
class FunniestRound {
  const FunniestRound({
    required this.matchId,
    required this.round,
    required this.votes,
    required this.player1Username,
    required this.player2Username,
    required this.videoUrl,
    required this.roundCount,
  });

  final String matchId;

  /// Zero-based round index judges found funniest, or null if unknown.
  final int? round;
  final int votes;
  final String player1Username;
  final String player2Username;
  final String? videoUrl;
  final int roundCount;

  static FunniestRound fromMap(Map<String, dynamic> m) => FunniestRound(
        matchId: m['matchId'] as String? ?? '',
        round: (m['round'] as num?)?.toInt(),
        votes: (m['votes'] as num?)?.toInt() ?? 0,
        player1Username: m['player1Username'] as String? ?? 'Player 1',
        player2Username: m['player2Username'] as String? ?? 'Player 2',
        videoUrl: m['videoUrl'] as String?,
        roundCount: (m['roundCount'] as num?)?.toInt() ?? 3,
      );
}

class FunniestRoundsService {
  Future<List<FunniestRound>> fetch({int limit = 20}) async {
    final result = await FirebaseFunctions.instance
        .httpsCallable('getFunniestRounds')
        .call<Map<String, dynamic>>({'limit': limit});
    final rounds = (result.data['rounds'] as List?) ?? const [];
    return rounds
        .map((r) => FunniestRound.fromMap((r as Map).cast<String, dynamic>()))
        .toList();
  }
}
