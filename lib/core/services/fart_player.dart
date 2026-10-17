import 'dart:math';

import 'package:audioplayers/audioplayers.dart';

/// Plays the fart ability's sound effects (the Fart power-up).
///
/// LOCAL ONLY, on purpose: this plays a bundled asset through the device's
/// own audio, NEVER through the Agora stream - so the fart is a live hindrance
/// the target hears, but it is NOT captured in the recording (the same
/// client-only, never-recorded rule as the tomato splat).
///
/// There are [_count] clips (assets/audio/farts/fart1.mp3 .. fartN.mp3); a
/// random one plays each time. Failures are swallowed - a missing/again-tapped
/// sound must never disrupt a battle.
class FartPlayer {
  FartPlayer();

  final AudioPlayer _player = AudioPlayer();
  final Random _rand = Random();

  /// How many fart clips are bundled. Keep in step with assets/audio/farts/.
  static const int _count = 4;

  Future<void> playRandom() async {
    final n = _rand.nextInt(_count) + 1; // 1.._count
    try {
      // AssetSource paths are relative to the `assets/` root.
      await _player.play(AssetSource('audio/farts/fart$n.mp3'));
    } catch (_) {
      // Never let a sound effect break the match.
    }
  }

  void dispose() {
    _player.dispose();
  }
}
