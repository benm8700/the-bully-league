import 'dart:async';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

/// Check-in for a LIVE tournament.
///
/// WHY THIS IS A REAL GATE RATHER THAN A FORMALITY. A live bracket is
/// built from whoever is actually present when it starts, not from
/// everyone who entered - because building from all entrants and
/// forfeiting the absentees produces a first round mostly of walkovers,
/// which is not a show and wastes the time of the people who did turn up.
/// So missing check-in means missing the tournament, and that has to be
/// said plainly enough that nobody discovers it afterwards.
///
/// Renders nothing at all for an async tournament, which has no check-in.
class LiveCheckIn extends StatefulWidget {
  const LiveCheckIn({
    super.key,
    required this.tournamentId,
    required this.tournament,
    required this.isEntrant,
  });

  final String tournamentId;
  final Map<String, dynamic> tournament;
  final bool isEntrant;

  @override
  State<LiveCheckIn> createState() => _LiveCheckInState();
}

class _LiveCheckInState extends State<LiveCheckIn> {
  Timer? _ticker;
  bool _busy = false;
  bool? _checkedIn;
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

  Future<void> _checkIn() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await FirebaseFunctions.instance
          .httpsCallable('checkInToTournament')
          .call<Map<String, dynamic>>({'tournamentId': widget.tournamentId});
      if (mounted) {
        setState(() {
          _busy = false;
          _checkedIn = true;
        });
      }
    } on FirebaseFunctionsException catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = e.message ?? 'Could not check in.';
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

    return Card(
      color: open ? scheme.primaryContainer : null,
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
            Text(
              started
                  ? 'Under way.'
                  : open
                      ? 'Starts in ${_countdown(until)}. Check in now.'
                      : 'Starts in ${_countdown(until)}. Check-in opens '
                          '$_leadMinutes minutes before.',
              style: text.bodyMedium,
            ),
            if (widget.isEntrant && !started) ...[
              const SizedBox(height: 6),
              Text(
                // The consequence, said before it happens rather than
                // discovered afterwards.
                'The bracket is built from whoever has checked in when it '
                'starts. Miss it and you are not in it.',
                style: text.bodySmall,
              ),
              const SizedBox(height: 10),
              if (_checkedIn == true)
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.check_circle, size: 18, color: scheme.primary),
                    const SizedBox(width: 6),
                    Text('You are checked in', style: text.bodyMedium),
                  ],
                )
              else
                FilledButton(
                  onPressed: (_busy || !open) ? null : _checkIn,
                  child: Text(open ? 'Check in' : 'Check-in not open yet'),
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
