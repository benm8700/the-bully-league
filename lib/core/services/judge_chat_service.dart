import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';

/// One message in the Main Stage judges' chat.
class JudgeChatMessage {
  const JudgeChatMessage({
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

/// Reads + posts the Main Stage judges' private chat. Clients read the room
/// directly (a cheap listener; firestore.rules lets only seated judges read it)
/// and post only through the postJudgeChatMessage callable, which re-checks the
/// seated-judge gate, moderates and rate-limits.
class JudgeChatService {
  JudgeChatService({FirebaseFirestore? firestore, FirebaseFunctions? functions})
      : _db = firestore ?? FirebaseFirestore.instance,
        _functions = functions ?? FirebaseFunctions.instance;

  final FirebaseFirestore _db;
  final FirebaseFunctions _functions;

  /// Live message stream, oldest first (so the newest sits at the bottom).
  Stream<List<JudgeChatMessage>> watch(String tournamentId) {
    return _db
        .collection('tournaments')
        .doc(tournamentId)
        .collection('judgeChat')
        .orderBy('createdAt')
        .limitToLast(100)
        .snapshots()
        .map((snap) => snap.docs.map((d) {
              final m = d.data();
              return JudgeChatMessage(
                id: d.id,
                uid: (m['uid'] as String?) ?? '',
                username: (m['username'] as String?) ?? 'Judge',
                text: (m['text'] as String?) ?? '',
              );
            }).toList());
  }

  /// Post a message. Throws [FirebaseFunctionsException] with the server's
  /// reason (too fast, blocked content, not a seated judge) so the UI can show
  /// it.
  Future<void> post(String tournamentId, String text) async {
    await _functions
        .httpsCallable('postJudgeChatMessage')
        .call<Map<String, dynamic>>({
      'tournamentId': tournamentId,
      'text': text,
    });
  }
}
