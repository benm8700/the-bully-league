import 'dart:math';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';

/// Plays the fart ability's sound effects (the Fart power-up).
///
/// LOCAL ONLY, on purpose: this plays a bundled asset through the device's
/// own audio, NEVER through the Agora stream - so the fart is a live hindrance
/// the target hears, but it is NOT captured in the recording (the same
/// client-only, never-recorded rule as the tomato splat).
///
/// AUDIO ROUTING MATTERS HERE. A battle has a LIVE Agora voice call, which
/// puts Android into communication audio mode and silences/attenuates the
/// normal MEDIA stream - so a fart played as ordinary media is inaudible. We
/// route it on the ALARM usage, which is the one stream Android keeps audible
/// regardless of call state and always sends to the speaker. (The subtler
/// "call-signalling" usage works on some phones but Samsung routes it to the
/// earpiece mid-call, so it was silent there - alarm is audible on both.)
///
/// There are [_count] clips (assets/audio/farts/fart1.mp3 .. fartN.mp3); a
/// random one plays each time. Failures are swallowed - a missing/again-tapped
/// sound must never disrupt a battle.
class FartPlayer {
  FartPlayer();

  final AudioPlayer _player = AudioPlayer();
  final Random _rand = Random();
  bool _contextSet = false;

  /// How many fart clips are bundled. Keep in step with assets/audio/farts/.
  static const int _count = 4;

  Future<void> _ensureContext() async {
    if (_contextSet) return;
    try {
      await _player.setAudioContext(
        AudioContext(
          android: const AudioContextAndroid(
            contentType: AndroidContentType.music,
            usageType: AndroidUsageType.alarm,
            audioFocus: AndroidAudioFocus.gain,
          ),
        ),
      );
      _contextSet = true;
    } catch (e) {
      // If routing can't be set, fall through and try to play anyway.
      debugPrint('FartPlayer: setAudioContext failed: $e');
    }
  }

  Future<void> playRandom() async {
    await _ensureContext();
    final n = _rand.nextInt(_count) + 1; // 1.._count
    try {
      // AssetSource paths are relative to the `assets/` root.
      debugPrint('FartPlayer: playing audio/farts/fart$n.mp3');
      await _player.play(AssetSource('audio/farts/fart$n.mp3'));
      debugPrint('FartPlayer: play() returned for fart$n.mp3');
    } catch (e) {
      // Never let a sound effect break the match.
      debugPrint('FartPlayer: play() failed: $e');
    }
  }

  void dispose() {
    _player.dispose();
  }
}
