import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';

import '../screens/friends/challenge_screen.dart' show startChallengeMatch;
import 'incoming_challenge_card.dart';

/// THE INCOMING-CHALLENGE POP-UP (2026-11-11, developer's call).
///
/// A friend challenge is the growth loop's most important moment (the person
/// challenged often installed the app just to answer it) and it expires in an
/// hour, so it gets a pop-up on top of the Home banner. Rules:
///  - Shown only from MainShell's pop-up queue, which only runs while Home is
///    the visible screen - never over a battle, the queue, Judge or recording.
///  - ONCE per challenge per app session ("Not now" closes it; the slim Home
///    banner stays as the reminder until it expires).
///  - Highest priority in the queue: it is the only pop-up that expires.
class ChallengePopup {
  static final Set<String> _shown = <String>{};

  /// True when there is an incoming challenge the player hasn't been
  /// popped for yet (cheap check for the queue's "something new" trigger).
  static bool isNew(String? challengeId) =>
      challengeId != null && !_shown.contains(challengeId);

  /// Mark a challenge as already presented (e.g. the player tapped its banner).
  static void markShown(String challengeId) => _shown.add(challengeId);

  /// Shows the pop-up for the newest unseen incoming challenge, if any.
  /// Returns true if the player ACCEPTED (they are now heading into a battle,
  /// so the caller should stop showing pop-ups).
  static Future<bool> maybeShow(BuildContext context) async {
    try {
      final r = await FirebaseFunctions.instance
          .httpsCallable('getMyChallenges')
          .call<Map<String, dynamic>>();
      final incoming = (r.data['incoming'] as List?) ?? const [];
      Map<String, dynamic>? pick;
      for (final c in incoming) {
        final m = (c as Map).cast<String, dynamic>();
        if (isNew(m['challengeId'] as String?)) {
          pick = m;
          break;
        }
      }
      if (pick == null || !context.mounted) return false;
      return await show(context, pick);
    } catch (_) {
      return false; // never break a session over a pop-up
    }
  }

  /// Shows the pop-up for [challenge]. Returns true if accepted.
  static Future<bool> show(
    BuildContext context,
    Map<String, dynamic> challenge,
  ) async {
    final id = challenge['challengeId'] as String?;
    if (id == null) return false;
    _shown.add(id);
    final matchId = await showGeneralDialog<String>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'challenge',
      barrierColor: Colors.black.withValues(alpha: 0.78),
      transitionDuration: const Duration(milliseconds: 320),
      pageBuilder: (_, _, _) => const SizedBox.shrink(),
      transitionBuilder: (dialogContext, anim, _, _) {
        final curved = CurvedAnimation(parent: anim, curve: Curves.easeOutBack);
        return FadeTransition(
          opacity: anim,
          child: ScaleTransition(
            scale: Tween(begin: 0.88, end: 1.0).animate(curved),
            child: _ChallengeDialog(challenge: challenge),
          ),
        );
      },
    );
    if (matchId == null || !context.mounted) return false;
    await startChallengeMatch(context, matchId);
    return true;
  }
}

class _ChallengeDialog extends StatefulWidget {
  const _ChallengeDialog({required this.challenge});

  final Map<String, dynamic> challenge;

  @override
  State<_ChallengeDialog> createState() => _ChallengeDialogState();
}

class _ChallengeDialogState extends State<_ChallengeDialog> {
  bool _busy = false;
  String? _error;

  Future<void> _accept() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final r = await FirebaseFunctions.instance
          .httpsCallable('respondToChallenge')
          .call<Map<String, dynamic>>({
            'challengeId': widget.challenge['challengeId'],
            'accept': true,
          });
      if (!mounted) return;
      Navigator.of(context).pop(r.data['matchId'] as String?);
    } on FirebaseFunctionsException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e.message ?? 'Could not accept that.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Material(
            color: Colors.transparent,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                IncomingChallengeCard(
                  fromUsername: '${widget.challenge['fromUsername']}',
                  expiresAtMs: widget.challenge['expiresAtMs'],
                  busy: _busy,
                  acceptLabel: 'Accept challenge',
                  declineLabel: 'Not now',
                  onAccept: _accept,
                  onDecline: () => Navigator.of(context).pop(),
                ),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: Text(
                      _error!,
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Color(0xFFFF6B6B)),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
