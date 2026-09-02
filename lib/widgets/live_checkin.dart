import 'dart:async';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

/// The single "Join tonight's tournament" control for a LIVE tournament.
///
/// ONE TAP, not two (2026-08-31). The old flow was enter-the-tournament then
/// check-in-during-the-window, and it read as a trap: "I'm in tonight" looked
/// like entry but did nothing toward the bracket, and a player could show up
/// and not be in it. Now this button appears when the window opens (~15
/// minutes before the start) and one tap enters AND checks you in, straight
/// into the bracket that forms at the start.
///
/// WHY IT IS STILL A REAL GATE. A live bracket is built from whoever joined
/// by the time it starts, not from everyone who ever showed interest -
/// building from absentees produces a first round of walkovers, which is not
/// a show. So joining has a window, and missing it means missing the
/// tournament - said plainly enough that nobody discovers it afterwards.
///
/// Renders nothing at all for an async tournament, which has no join window.
class LiveCheckIn extends StatefulWidget {
  const LiveCheckIn({
    super.key,
    required this.tournamentId,
    required this.tournament,
    required this.checkedIn,
  });

  final String tournamentId;
  final Map<String, dynamic> tournament;

  /// Whether the signed-in player is already in tonight's bracket (their
  /// entrant document records a check-in).
  final bool checkedIn;

  @override
  State<LiveCheckIn> createState() => _LiveCheckInState();
}

class _LiveCheckInState extends State<LiveCheckIn> {
  Timer? _ticker;
  bool _busy = false;
  bool _joined = false;
  String? _error;

  /// Mirrors DEFAULT_CHECKIN_LEAD_MS in functions/liveTournament.js. If
  /// these drift the screen offers a button the server refuses, which
  /// reads as broken rather than as early.
  static const _leadMinutes = 15;

  @override
  void initState() {
    super.initState();
    // Ticks so the countdown moves and the button appears the moment
    // check-in opens, without the player reloading the screen.
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  int? get _startsAtMs {
    final raw = widget.tournament['startsAtMs'];
    if (raw is num && raw > 0) return raw.toInt();
    return null;
  }

  bool get _isLive => widget.tournament['format'] == 'live';

  Future<void> _join() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      // checkInToTournament now enters AND checks in for a free live
      // tournament - one call for the one-tap Join.
      await FirebaseFunctions.instance
          .httpsCallable('checkInToTournament')
          .call<Map<String, dynamic>>({'tournamentId': widget.tournamentId});
      if (mounted) {
        setState(() {
          _busy = false;
          _joined = true;
        });
      }
    } on FirebaseFunctionsException catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = e.message ?? 'Could not join.';
        });
      }
    }
  }

  String _countdown(Duration d) {
    if (d.inHours >= 1) return '${d.inHours}h ${d.inMinutes % 60}m';
    if (d.inMinutes >= 1) return '${d.inMinutes}m ${d.inSeconds % 60}s';
    return '${d.inSeconds}s';
  }

  @override
  Widget build(BuildContext context) {
    if (!_isLive) return const SizedBox.shrink();
    final startsAt = _startsAtMs;
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;

    if (startsAt == null) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Text('Live event - start time to be announced.',
              style: text.bodyMedium),
        ),
      );
    }

    final now = DateTime.now().millisecondsSinceEpoch;
    final until = Duration(milliseconds: startsAt - now);
    final open = until.inMinutes < _leadMinutes && !until.isNegative;
    final started = until.isNegative;
    final inBracket = widget.checkedIn || _joined;

    return Card(
      color: (open && !inBracket) ? scheme.primaryContainer : null,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(Icons.podcasts_outlined, size: 18),
                const SizedBox(width: 8),
                Text('Live event', style: text.titleSmall),
              ],
            ),
            const SizedBox(height: 6),
            // Already in the bracket - the same message whether they joined
            // just now or the round has started.
            if (inBracket)
              Row(
                children: [
                  Icon(Icons.check_circle, size: 18, color: scheme.primary),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      started
                          ? 'You are in the bracket. Your match is coming up.'
                          : 'You are in tonight\'s bracket. Sit tight - it '
                              'kicks off in ${_countdown(until)}.',
                      style: text.bodyMedium,
                    ),
                  ),
                ],
              )
            else if (started)
              // Missed it: the bracket is set and they are not in it.
              Text(
                'The bracket is set. You can still find a one-on-one any time.',
                style: text.bodyMedium,
              )
            else if (!open)
              Text(
                'Starts in ${_countdown(until)}. Join opens '
                '$_leadMinutes minutes before.',
                style: text.bodyMedium,
              )
            else ...[
              // The window is open and they are not in yet: the single Join.
              Text(
                'Starts in ${_countdown(until)}. Tap Join to get in - the '
                'bracket locks when it kicks off.',
                style: text.bodyMedium,
              ),
              const SizedBox(height: 10),
              FilledButton(
                onPressed: _busy ? null : _join,
                child: const Text('Join tonight\'s tournament'),
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!,
                  style: text.bodySmall?.copyWith(color: scheme.error)),
            ],
          ],
        ),
      ),
    );
  }
}

/// Whether the signed-in player has already checked in, read from their own
/// entrant document.
///
/// Kept separate from the widget so the detail screen's existing entrants
/// stream stays the single source of who is in - one listener, not two.
bool hasCheckedIn(Map<String, dynamic>? entrant) {
  final raw = entrant?['checkedInAtMs'];
  return raw is num && raw > 0;
}

/// The uid this widget speaks for, or null when signed out.
String? currentUid() => FirebaseAuth.instance.currentUser?.uid;
