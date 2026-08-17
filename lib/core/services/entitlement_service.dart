import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart';

/// What the signed-in player may do right now.
///
/// Mirrors functions/entitlement.js. The server remains the authority -
/// enterQueue enforces regardless - so this exists purely so the app can
/// make an OFFER at the right moment instead of letting someone walk
/// through the tutorial gate, the recording consent screen and the whole
/// camera-and-mic check only to be turned away at the queue. That is the
/// worst possible moment to say no: the refusal reads as a bug rather than
/// a price.
@immutable
class Entitlement {
  const Entitlement({
    required this.state,
    required this.inWindow,
    required this.enforced,
    required this.rankedAllowed,
    required this.practiceAllowed,
    required this.blockedMessage,
    required this.trialEndsAtMs,
    required this.windowName,
  });

  /// 'trial' | 'subscriber' | 'lapsed'
  final String state;
  final bool inWindow;
  final bool enforced;
  final bool rankedAllowed;
  final bool practiceAllowed;
  final String? blockedMessage;
  final int? trialEndsAtMs;
  final String? windowName;

  /// Assumes full access. Used when the check can't be reached, so a
  /// transient error never blocks someone from playing - the server will
  /// still refuse if it genuinely should.
  static const permissive = Entitlement(
    state: 'trial',
    inWindow: false,
    enforced: false,
    rankedAllowed: true,
    practiceAllowed: true,
    blockedMessage: null,
    trialEndsAtMs: null,
    windowName: null,
  );

  bool allows(String mode) => mode == 'ranked' ? rankedAllowed : practiceAllowed;

  /// Whole days remaining, or null when the trial has no known end. Rounded
  /// UP so the last partial day reads as "1 day left" rather than "0".
  int? get trialDaysLeft {
    if (state != 'trial' || trialEndsAtMs == null) return null;
    final ms = trialEndsAtMs! - DateTime.now().millisecondsSinceEpoch;
    if (ms <= 0) return 0;
    return (ms / Duration.millisecondsPerDay).ceil();
  }

  factory Entitlement.fromMap(Map<String, dynamic> data) {
    final ranked = (data['ranked'] as Map?)?.cast<String, dynamic>();
    final practice = (data['exhibition'] as Map?)?.cast<String, dynamic>();
    return Entitlement(
      state: data['state'] as String? ?? 'trial',
      inWindow: data['inWindow'] == true,
      enforced: data['enforced'] == true,
      rankedAllowed: ranked?['allowed'] != false,
      practiceAllowed: practice?['allowed'] != false,
      blockedMessage: ranked?['message'] as String?,
      trialEndsAtMs: (data['trialEndsAtMs'] as num?)?.toInt(),
      windowName: data['windowName'] as String?,
    );
  }
}

class EntitlementService {
  EntitlementService({FirebaseFunctions? functions})
      : _functions = functions ?? FirebaseFunctions.instance;

  final FirebaseFunctions _functions;

  /// Fails OPEN. A network blip must never look like a paywall - the
  /// server still enforces, so the worst case is that someone is shown an
  /// action they then get refused for, which is far better than being told
  /// they must pay when they need not.
  Future<Entitlement> current() async {
    try {
      final result = await _functions
          .httpsCallable('getMyEntitlement')
          .call<Map<String, dynamic>>();
      return Entitlement.fromMap(result.data);
    } catch (_) {
      return Entitlement.permissive;
    }
  }
}
