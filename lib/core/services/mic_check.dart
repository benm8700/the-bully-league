/// The pre-match mic check: "Checking the room" then 'Say "THE BULLY LEAGUE"'.
///
/// WHY TWO STEPS (2026-11-10). Every earlier version only asked "is something
/// loud enough?", so background noise and a person talking looked the same:
/// any threshold was either too strict (six tries) or too easy (a TV passed
/// it). This measures the ROOM first, while the player is quiet, then judges
/// the voice against it:
///
///  1. ROOM: [roomMs] of listening. If the room's median level is above
///     [noisyLevel] the room is TOO NOISY (TV, music, people) - the player is
///     told and the room is measured again until it settles.
///  2. SPEAK: only now does it listen for the phrase. A report counts when the
///     voice detector heard voice (within [voiceHoldMs] - it lags a beat) and
///     the level is at least [minLevel] and [margin] above the measured room.
///     A level at or above [tooLoudLevel] is TOO LOUD (shouting/right on the
///     mic) and does not count. [needed] counted reports, close together,
///     pass - about 0.6s, inside the ~0.8s phrase.
///
/// Noise before the speak step can't help anyone pass: it either fails the
/// room check or raises the bar the voice is judged against.
enum MicPhase { room, tooNoisy, speak, passed }

class MicCheck {
  MicCheck({
    this.roomMs = 1500,
    this.noisyLevel = 14,
    this.minLevel = 12,
    this.margin = 12,
    this.tooLoudLevel = 200,
    this.needed = 3,
    this.voiceHoldMs = 600,
    this.resetAfterMs = 1500,
  });

  final int roomMs;
  final int noisyLevel;
  final int minLevel;
  final int margin;
  final int tooLoudLevel;
  final int needed;
  final int voiceHoldMs;
  final int resetAfterMs;

  MicPhase _phase = MicPhase.room;
  int? _roomStartMs;
  final List<int> _roomLevels = [];
  int _room = 0;
  int _count = 0;
  int? _lastCountedMs;
  int? _lastVadMs;
  int? _tooLoudAtMs;

  MicPhase get phase => _phase;
  bool get passed => _phase == MicPhase.passed;

  /// The measured room level (median of the room step).
  int get roomLevel => _room;

  /// Whether the room measured quiet enough (null until measured).
  bool? get roomQuiet =>
      _phase == MicPhase.room ? null : _phase != MicPhase.tooNoisy;

  /// The level a voice must reach in the speak step.
  int get bar => (_room + margin) > minLevel ? _room + margin : minLevel;

  /// True for ~1.5s after a too-loud report, so the UI can say so.
  bool tooLoudAt(int nowMs) =>
      _tooLoudAtMs != null && nowMs - _tooLoudAtMs! < 1500;

  /// Feeds one level report (0-255, ~every 200ms). Returns the phase after it.
  MicPhase add({required int level, required bool voice, required int nowMs}) {
    switch (_phase) {
      case MicPhase.passed:
        return _phase;
      case MicPhase.room:
      case MicPhase.tooNoisy:
        _roomStartMs ??= nowMs;
        _roomLevels.add(level);
        if (nowMs - _roomStartMs! >= roomMs) {
          final sorted = [..._roomLevels]..sort();
          _room = sorted[sorted.length ~/ 2];
          _roomLevels.clear();
          _roomStartMs = null;
          _phase = _room > noisyLevel ? MicPhase.tooNoisy : MicPhase.speak;
        }
        return _phase;
      case MicPhase.speak:
        if (voice) _lastVadMs = nowMs;
        if (level >= tooLoudLevel) {
          _tooLoudAtMs = nowMs;
          return _phase;
        }
        final voiceRecent =
            _lastVadMs != null && nowMs - _lastVadMs! <= voiceHoldMs;
        if (voiceRecent && level >= bar) {
          if (_lastCountedMs != null &&
              nowMs - _lastCountedMs! > resetAfterMs) {
            _count = 0;
          }
          _count++;
          _lastCountedMs = nowMs;
          if (_count >= needed) _phase = MicPhase.passed;
        } else if (_lastCountedMs != null &&
            nowMs - _lastCountedMs! > resetAfterMs) {
          _count = 0;
        }
        return _phase;
    }
  }
}
