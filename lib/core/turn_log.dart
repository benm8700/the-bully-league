import 'main_stage_battle.dart';

/// THE CLIP STRIP's clock (2026-11-15). The HOST phone logs every change of
/// the battle state - who holds the mic, which turn, both clocks - with its
/// wall-clock time, and sends the log with completeMatch. The server moves it
/// onto its own clock and the clip renderer (functions/clipStrip.js) burns
/// the turn clock, the round and the lit speaker name into the highlight clip
/// at the right moments.
///
/// Only changes are logged (one entry per turn, interrupt or end), never
/// the 300ms ticks, so a whole battle is a dozen entries.
class TurnLog {
  static const _maxEntries = 300;

  final List<Map<String, Object?>> _entries = [];
  String? _lastKey;
  MainStageBattleConfig? _config;
  List<String>? _players;

  bool get isEmpty => _entries.isEmpty;

  /// Call with every new HOST state.
  void record(MainStageBattleState b, int nowMs) {
    if (b.status == MsStatus.pending) return;
    final key = '${b.status.name}|${b.floor}|${b.turn}|${b.pendingBy}';
    if (key == _lastKey || _entries.length >= _maxEntries) return;
    _lastKey = key;
    _config = b.config;
    _players = b.players;
    final r = <String, int>{};
    for (final p in b.players) {
      var ms = b.remaining[p] ?? 0;
      // The holder's clock is settled at lastMs; bring it up to now.
      if (p == b.floor && b.talking && b.lastMs != null) {
        ms -= nowMs - b.lastMs!;
      }
      r[p] = ms < 0 ? 0 : ms;
    }
    _entries.add({
      't': nowMs,
      'f': b.floor,
      'n': b.turn,
      'r': r,
      if (b.isOver) 'o': 1,
    });
  }

  /// The report for completeMatch, or null when nothing was logged.
  Map<String, Object?>? toReport(int nowMs) {
    final c = _config;
    final players = _players;
    if (_entries.isEmpty || c == null || players == null) return null;
    return {
      'v': 1,
      'sentAt': nowMs,
      'kind': c.isRounds ? 'rounds' : 'chess',
      if (c.isRounds) 'turnMs': c.turnMs,
      if (c.isRounds) 'turnCount': c.turnCount,
      'players': players,
      'e': _entries,
    };
  }
}
