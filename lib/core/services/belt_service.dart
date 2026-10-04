import 'package:cloud_firestore/cloud_firestore.dart';

/// The current holder of THE BELT - the app's one losable "title fight" honour,
/// held by whoever most recently won the Daily Gauntlet. Read-only here:
/// stats/belt is written only by the onTournamentCompleted trigger (Admin SDK),
/// and is client-readable, so this is a plain Firestore read.
class BeltHolder {
  const BeltHolder({this.holderUid, this.holderName, this.defenseCount = 0});

  final String? holderUid;
  final String? holderName;

  /// How many times the current holder has successfully defended (won the
  /// gauntlet again in a row). 0 = just took it.
  final int defenseCount;

  bool get hasHolder => holderUid != null && holderUid!.isNotEmpty;

  factory BeltHolder.fromData(Map<String, dynamic>? d) {
    if (d == null) return const BeltHolder();
    return BeltHolder(
      holderUid: d['holderUid'] as String?,
      holderName: d['holderName'] as String?,
      defenseCount: (d['defenseCount'] as num?)?.toInt() ?? 0,
    );
  }
}

class BeltService {
  static final DocumentReference<Map<String, dynamic>> _doc =
      FirebaseFirestore.instance.collection('stats').doc('belt');

  /// Live stream of the belt holder (empty holder until someone wins one).
  static Stream<BeltHolder> watch() =>
      _doc.snapshots().map((s) => BeltHolder.fromData(s.data()));

  /// One-shot read, used where a stream would be overkill (e.g. a bio reveal).
  static Future<BeltHolder> get() async {
    try {
      return BeltHolder.fromData((await _doc.get()).data());
    } catch (_) {
      return const BeltHolder();
    }
  }
}
