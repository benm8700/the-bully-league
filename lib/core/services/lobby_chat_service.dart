import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';

/// One message in the Main Stage viewers' lobby chat.
class LobbyChatMessage {
  const LobbyChatMessage({
    required this.id,
    required this.uid,
    required this.username,
    required this.text,
  });

  final String id;
  final String uid;
  final String username;
  final String text;
}

/// Reads + posts the Main Stage viewers' LOBBY chat - the whole-crowd room where
/// the audience hangs out and talks about the battles. Clients read the room
/// directly (a cheap listener; firestore.rules lets any signed-in user read it)
/// and post only through the postLobbyMessage callable, which moderates
/// (hate/slur filter, edgy comedy allowed) and rate-limits. Wiped when the
/// tournament ends (onGauntletEnded), so a night's chat never outlives the show.
class LobbyChatService {
  LobbyChatService({FirebaseFirestore? firestore, FirebaseFunctions? functions})
      : _db = firestore ?? FirebaseFirestore.instance,
        _functions = functions ?? FirebaseFunctions.instance;

  final FirebaseFirestore _db;
  final FirebaseFunctions _functions;

  /// Live message stream, oldest first (newest at the bottom).
  Stream<List<LobbyChatMessage>> watch(String tournamentId) {
    return _db
        .collection('tournaments')
        .doc(tournamentId)
        .collection('lobbyChat')
        .orderBy('createdAt')
        .limitToLast(100)
        .snapshots()
        .map((snap) => snap.docs.map((d) {
              final m = d.data();
              return LobbyChatMessage(
                id: d.id,
                uid: (m['uid'] as String?) ?? '',
                username: (m['username'] as String?) ?? 'Roaster',
                text: (m['text'] as String?) ?? '',
              );
            }).toList());
  }

  /// Post a message. Throws [FirebaseFunctionsException] with the server's
  /// reason (too fast / blocked content) so the UI can show it.
  Future<void> post(String tournamentId, String text) async {
    await _functions
        .httpsCallable('postLobbyMessage')
        .call<Map<String, dynamic>>({
      'tournamentId': tournamentId,
      'text': text,
    });
  }
}
