import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

/// Fame: following comedians.
///
/// A follow is an own-write document at
/// `follows/{targetUid}/followers/{myUid}` — firestore.rules allows a client
/// to write only its OWN membership doc, so one account can add at most one
/// follower to a target. The authoritative `followerCount` on the target's
/// user doc is maintained server-side by the onFollow* triggers and is never
/// client-writable, so the Fame board can't be inflated beyond one-per-account.
///
/// This is deliberately reward-free (see CLAUDE.md's fame notes): the payoff
/// of followers is being someone's live crowd, plus the count and the board —
/// never currency or power — which is what keeps it un-farmable.
class FollowsService {
  FollowsService({FirebaseFirestore? db, FirebaseAuth? auth})
      : _db = db ?? FirebaseFirestore.instance,
        _auth = auth ?? FirebaseAuth.instance;

  final FirebaseFirestore _db;
  final FirebaseAuth _auth;

  String? get _me => _auth.currentUser?.uid;

  DocumentReference<Map<String, dynamic>> _membershipDoc(String targetUid) =>
      _db.collection('follows').doc(targetUid).collection('followers').doc(_me);

  /// Live "am I following this person" for the Follow button. Emits false
  /// when signed out or for your own profile (you can't follow yourself).
  Stream<bool> isFollowing(String targetUid) {
    final me = _me;
    if (me == null || me == targetUid) return Stream.value(false);
    return _membershipDoc(targetUid).snapshots().map((s) => s.exists);
  }

  /// Follow [targetUid]. No-op on self. Own-write, so it responds instantly.
  Future<void> follow(String targetUid) async {
    final me = _me;
    if (me == null || me == targetUid) return;
    await _membershipDoc(targetUid).set({
      'followerUid': me,
      'createdAt': FieldValue.serverTimestamp(),
    });
  }

  /// Unfollow [targetUid].
  Future<void> unfollow(String targetUid) async {
    final me = _me;
    if (me == null || me == targetUid) return;
    await _membershipDoc(targetUid).delete();
  }
}

/// Reads a follower count off a user document defensively.
int followerCountOf(Map<String, dynamic>? user) =>
    ((user?['followerCount'] as num?) ?? 0).toInt();
