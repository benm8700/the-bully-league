import 'package:cloud_firestore/cloud_firestore.dart';

/// How many people are queueing or mid-match right now, published once a
/// minute by the `publishOnlineCount` Cloud Function.
///
/// The count's only value is being true - it exists to answer "will anyone
/// be there?", and an inflated number sends someone into an empty queue and
/// teaches them the app is dead. So this errs hard towards showing nothing:
/// a missing document, an unreadable one, or a count published too long ago
/// all render as "unknown" rather than as a guess.
class OnlineCount {
  const OnlineCount({
    required this.waiting,
    required this.matched,
    required this.total,
    required this.updatedAt,
  });

  final int waiting;
  final int matched;
  final int total;
  final DateTime? updatedAt;

  /// The publisher runs every minute, so anything much older than that
  /// means it has stopped running. Showing a frozen number from an hour ago
  /// would be worse than showing none - it is the precise failure this
  /// counter must not have.
  static const Duration _maxAge = Duration(minutes: 5);

  bool get isFresh {
    final at = updatedAt;
    if (at == null) return false;
    return DateTime.now().toUtc().difference(at.toUtc()) <= _maxAge;
  }

  static OnlineCount? fromMap(Map<String, dynamic>? data) {
    if (data == null) return null;
    final updatedAt = data['updatedAt'];
    return OnlineCount(
      waiting: (data['waiting'] as num?)?.toInt() ?? 0,
      matched: (data['matched'] as num?)?.toInt() ?? 0,
      total: (data['total'] as num?)?.toInt() ?? 0,
      updatedAt: updatedAt is Timestamp ? updatedAt.toDate() : null,
    );
  }

  /// Phrased as people rather than as a bare number, because "3 roasters
  /// online" reads as a room and "3" reads as a statistic.
  String get label {
    if (total == 1) return '1 roaster online now';
    return '$total roasters online now';
  }
}

Stream<OnlineCount?> onlineCountStream() {
  return FirebaseFirestore.instance
      .collection('stats')
      .doc('presence')
      .snapshots()
      .map((snap) => OnlineCount.fromMap(snap.data()))
      .handleError((_) => null);
}
