import 'package:cloud_functions/cloud_functions.dart';

/// Posts to the Daily Gauntlet lobby chat. The only write path - the callable
/// moderates, rate-limits and window-gates every message server-side.
class LobbyService {
  Future<void> post(String tournamentId, String text) async {
    await FirebaseFunctions.instance
        .httpsCallable('postLobbyMessage')
        .call<Map<String, dynamic>>({
      'tournamentId': tournamentId,
      'text': text,
    });
  }
}
