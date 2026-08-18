import 'dart:async';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart';

/// Timings for one match (CLAUDE.md's `config/matchSettings` schema).
///
/// Resolved SERVER-side once at pairing time and stamped onto the match
/// document, so both players are guaranteed to run identical numbers -
/// see functions/matchSettings.js for why that matters and why this is a
/// Firestore document rather than client-side Remote Config.
///
/// The defaults here are a last-resort safety net for an older match
/// document written before settings existed; the server has its own
/// copy of the same values.
class MatchSettings {
  const MatchSettings({
    this.roundCount = 3,
    this.roundLengthSeconds = 15,
    this.countdownSeconds = 5,
    this.bioRevealSeconds = 60,
  });

  final int roundCount;
  final int roundLengthSeconds;
  final int countdownSeconds;
  final int bioRevealSeconds;

  /// Total turns in a match - each round gives both players one turn.
  int get totalTurns => roundCount * 2;

  factory MatchSettings.fromMap(Map<String, dynamic>? map) {
    if (map == null) return const MatchSettings();
    const fallback = MatchSettings();
    int read(String key, int orElse) => (map[key] as num?)?.toInt() ?? orElse;
    return MatchSettings(
      roundCount: read('roundCount', fallback.roundCount),
      roundLengthSeconds: read('roundLengthSeconds', fallback.roundLengthSeconds),
      countdownSeconds: read('countdownSeconds', fallback.countdownSeconds),
      bioRevealSeconds: read('bioRevealSeconds', fallback.bioRevealSeconds),
    );
  }
}

/// A pairing handed back by the matchmaking backend - everything the match
/// flow needs to actually start: which Agora channel to join, which match
/// document to settle at the end, who the opponent is, and the timings
/// both sides will run.
class MatchPairing {
  const MatchPairing({
    required this.matchId,
    required this.channelName,
    required this.opponentId,
    required this.mode,
    this.settings = const MatchSettings(),
    this.agoraUid = 0,
    this.origin = 'live',
  });

  final String matchId;
  final String channelName;
  final String opponentId;
  final String mode;
  final MatchSettings settings;

  /// The fixed Agora uid to join the match channel with - 1 for player1,
  /// 2 for player2, assigned server-side at pairing.
  ///
  /// Not the wildcard 0 any more, because the recording layout has to name
  /// each player's region by uid and the server can't learn a
  /// dynamically-assigned one. 0 remains the fallback for an older pairing
  /// that predates this, where Agora assigns a uid as before.
  final int agoraUid;

  /// "standing" when this match came from a challenge left behind rather
  /// than a live pairing. Someone returning to it may have queued hours
  /// ago and forgotten, so the UI can explain itself instead of just
  /// announcing a match.
  final String origin;

  factory MatchPairing.fromMap(Map<String, dynamic> data, {String? fallbackMode}) {
    return MatchPairing(
      matchId: data['matchId'] as String,
      channelName: data['channelName'] as String,
      opponentId: data['opponentId'] as String,
      mode: data['mode'] as String? ?? fallbackMode ?? 'ranked',
      settings: MatchSettings.fromMap(
        (data['settings'] as Map?)?.cast<String, dynamic>(),
      ),
      agoraUid: (data['agoraUid'] as num?)?.toInt() ?? 0,
      origin: data['origin'] as String? ?? 'live',
    );
  }
}

/// Progress while still queued, so the UI can explain what's happening
/// rather than showing an indefinite spinner - [tierBand] is how far the
/// search has widened past the player's own tier (0 = same tier only).
class MatchmakingProgress {
  const MatchmakingProgress({
    required this.waited,
    required this.tierBand,
    this.judgePriorityMs = 0,
  });

  final Duration waited;
  final int tierBand;

  /// The head start today's judging earned, in milliseconds. Zero for
  /// almost everyone, so the UI only mentions it when it is real.
  final int judgePriorityMs;

  bool get hasJudgePriority => judgePriorityMs > 0;
}

/// Client half of real matchmaking (Build Order step 4's missing half).
///
/// The queue itself lives in Realtime Database and is reachable ONLY
/// through these Cloud Functions - see functions/matchmaking.js for why
/// (a queue entry carries the player's real rating and tier, so letting a
/// client write its own entry would let a modified client claim any rating
/// and hand-pick opponents).
///
/// [findMatch] polls rather than subscribing. That's deliberate: the
/// server widens the acceptable tier range the longer someone waits, so
/// something has to re-attempt pairing on a timer regardless, and polling
/// makes that the same mechanism instead of a second one. It also keeps
/// firebase_database off the Flutter side entirely, avoiding another
/// Android dependency in a toolchain CLAUDE.md documents as fragile.
class MatchmakingService {
  MatchmakingService({FirebaseFunctions? functions})
      : _functions = functions ?? FirebaseFunctions.instance;

  final FirebaseFunctions _functions;

  static const pollInterval = Duration(seconds: 3);

  Future<Map<String, dynamic>> _call(
      String name, Map<String, dynamic> args) async {
    final result =
        await _functions.httpsCallable(name).call<Map<String, dynamic>>(args);
    return result.data;
  }

  /// Joins the queue, then polls until paired or until [cancel] completes.
  ///
  /// [onProgress] fires on every unsuccessful poll so the UI can show wait
  /// time and how far the tier search has widened.
  ///
  /// Returns null if cancelled. Always leaves the queue on the way out -
  /// including on cancellation and on error - so a abandoned search can't
  /// leave an entry behind for someone else to be paired against.
  /// [standDown] is how someone walks away WITHOUT giving up their place.
  /// Once a search has run long enough it becomes a standing challenge that
  /// outlives the app being closed, and leaving the queue at that point
  /// would throw away the very thing that makes off-peak queueing work.
  /// Cancelling still leaves the queue; standing down does not.
  Future<MatchPairing?> findMatch({
    required String mode,
    required Future<void> cancel,
    Future<void>? standDown,
    void Function(MatchmakingProgress)? onProgress,
  }) async {
    var cancelled = false;
    var keepEntry = false;
    unawaited(cancel.then((_) => cancelled = true));
    unawaited(standDown?.then((_) {
      keepEntry = true;
      cancelled = true;
    }));

    try {
      // Any head start today's judging earned. Read once at entry - it
      // is fixed for the life of this queue entry, so re-reading it on
      // every poll would cost a round trip to learn nothing.
      final entered = await _call('enterMatchmakingQueue', {'mode': mode});
      final judgePriorityMs =
          (entered['judgePriorityMs'] as num?)?.toInt() ?? 0;

      while (!cancelled) {
        final result = await _functions
            .httpsCallable('pollMatchmaking')
            .call<Map<String, dynamic>>({'mode': mode});
        final data = result.data;

        switch (data['status'] as String?) {
          case 'matched':
            return MatchPairing.fromMap(data, fallbackMode: mode);
          case 'not_queued':
            // The entry was pruned as stale (a long background suspend, a
            // slow network) - re-enter rather than polling forever against
            // a queue we're no longer in.
            await _call('enterMatchmakingQueue', {'mode': mode});
          default:
            onProgress?.call(MatchmakingProgress(
              waited: Duration(milliseconds: (data['waitedMs'] as num?)?.toInt() ?? 0),
              tierBand: (data['tierBand'] as num?)?.toInt() ?? 0,
              judgePriorityMs: judgePriorityMs,
            ));
        }

        // Race the sleep against cancellation so tapping Cancel doesn't
        // hang for the rest of the interval before the UI responds.
        await Future.any([
          Future<void>.delayed(pollInterval),
          cancel,
          // ignore: use_null_aware_elements
          if (standDown != null) standDown,
        ]);
      }
      return null;
    } finally {
      // Standing down deliberately leaves the entry in place - that IS the
      // standing challenge, and removing it here would undo the whole
      // mechanism the moment someone closed the screen.
      if (!keepEntry) {
        // Best-effort: if this fails, the entry is pruned server-side once
        // it goes stale, so a dropped call delays cleanup rather than
        // corrupting the queue.
        try {
          await _call('leaveMatchmakingQueue', {'mode': mode});
        } catch (_) {}
      }
    }
  }



  /// Recovers a match this player was paired into but never collected -
  /// the cold-start case after tapping a match-found push, where the queue
  /// entry and match document both exist but the app has no idea about
  /// either. Returns null if there's nothing waiting.
  Future<MatchPairing?> activeMatch() async {
    try {
      final result =
          await _functions.httpsCallable('getActiveMatch').call<Map<String, dynamic>>();
      final data = result.data;
      if (data['found'] != true) return null;
      return MatchPairing.fromMap(data);
    } catch (_) {
      // Purely additive UI - if this check fails the player just doesn't
      // see the banner, which is no worse than before it existed.
      return null;
    }
  }

  /// Asks the backend to start recording this match. Called once by the
  /// host device as the match begins.
  ///
  /// Silently does nothing on failure, by design: recording is server-side
  /// (see functions/cloudRecording.js) and only covers ranked/tournament
  /// matches, so an exhibition match or an unconfigured backend both come
  /// back as "not started" — neither is something to interrupt two players
  /// mid-match about.
  Future<void> startRecording(String matchId) async {
    try {
      await _call('startMatchRecording', {'matchId': matchId});
    } catch (e) {
      debugPrint('Could not start match recording: $e');
    }
  }

  /// Marks the local player ready during the pre-match bio reveal. Both
  /// clients watch the match document, so this is how each learns the
  /// other has finished reading.
  Future<void> setReady(String matchId) async {
    await _call('setMatchReady', {'matchId': matchId});
  }

  /// Tells the backend this player is still on the bio reveal screen,
  /// without marking them ready.
  ///
  /// This is what lets a long reveal window be safe. The window ends as
  /// soon as both players tap Ready, so its maximum only ever matters when
  /// one of them doesn't - and the difference between "still reading their
  /// bio" and "walked away" cannot be told from readiness alone. Failures
  /// are swallowed: a missed heartbeat is not worth interrupting someone
  /// preparing for a battle, and the threshold tolerates several.
  Future<void> sendPresence(String matchId) async {
    try {
      await _call('setMatchReady', {'matchId': matchId, 'ready': false});
    } catch (_) {
      // Best-effort by design.
    }
  }

  /// Leaves a match whose opponent never turned up, without spending a
  /// skip - they declined nobody, they were stood up.
  Future<bool> releaseUnresponsive(String matchId) async {
    try {
      final result = await _functions
          .httpsCallable('releaseUnresponsiveMatch')
          .call<Map<String, dynamic>>({'matchId': matchId});
      return result.data['released'] == true;
    } catch (_) {
      // The server is the authority on whether a release is allowed; a
      // refusal means the opponent is still there, which is good news.
      return false;
    }
  }

  /// Declines a proposed match after seeing the opponent's bio. Spends one
  /// of the player's daily skips and settles the match as abandoned.
  ///
  /// Throws if the allowance is exhausted - the caller should surface that
  /// rather than silently swallowing it, since the player is expecting the
  /// match to end.
  Future<int> skipMatch(String matchId) async {
    final result = await _functions
        .httpsCallable('skipMatch')
        .call<Map<String, dynamic>>({'matchId': matchId});
    return (result.data['skipsRemaining'] as num?)?.toInt() ?? 0;
  }

  /// How many skips the player has left today, and how many of today's
  /// allowance came from judging.
  ///
  /// The breakdown matters because an allowance that silently grows is a
  /// reward nobody knows they got - and the skip button is the one place
  /// the reward is actually spent.
  Future<SkipAllowance> skipsRemaining() async {
    final result =
        await _functions.httpsCallable('getSkipAllowance').call<Map<String, dynamic>>();
    return SkipAllowance(
      remaining: (result.data['remaining'] as num?)?.toInt() ?? 0,
      earned: (result.data['earned'] as num?)?.toInt() ?? 0,
    );
  }

  /// Marks a paired match finished. [outcome] is 'completed' for a match
  /// played to a verdict, or 'abandoned' when it ended without a real
  /// contest (currently the live content-violation auto-end) - abandoned
  /// matches are never voted on or rated.
  /// Settles the match, optionally carrying this device's own
  /// capture-quality summary.
  ///
  /// The report describes THIS player's camera and mic, so both devices
  /// send their own and the server keys them by uid. It is advisory: it
  /// only deprioritises the clip for captions and never touches the
  /// result, so a missing or wrong report costs nothing that matters.
  Future<void> completeMatch(
    String matchId, {
    String outcome = 'completed',
    Map<String, Object?>? quality,
  }) async {
    await _call('completeMatch', {
      'matchId': matchId,
      'outcome': outcome,
      'quality': ?quality,
    });
  }
}

/// Today's skip allowance, and how much of it judging paid for.
class SkipAllowance {
  const SkipAllowance({required this.remaining, required this.earned});

  final int remaining;

  /// Extra skips earned by judging today. Zero for most players, so the
  /// UI only mentions it when it is actually non-zero.
  final int earned;
}
