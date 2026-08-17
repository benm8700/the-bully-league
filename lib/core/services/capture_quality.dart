/// Judging whether a player's own camera and mic are actually usable.
///
/// CLAUDE.md's Auto quality flags decision asks for detection of
/// too-dark, too-quiet, too-shaky and face-not-visible. **Only the first
/// two are implemented, deliberately.** Mean brightness and audio level
/// are cheap, reliable and unambiguous; shake needs frame-to-frame motion
/// analysis and face-visibility needs real face detection, and claiming
/// either from a heuristic would produce confident wrong answers about
/// somebody's match. Those two stay unbuilt rather than half-built.
///
/// WHAT THIS DOES NOT DO: cancel the match. CLAUDE.md's decision says a
/// flagged match is auto-cancelled and re-queued with no penalty, and
/// that is deliberately NOT implemented here - see the note in
/// CLAUDE.md. Two reasons: a false positive would destroy a real battle
/// somebody was in the middle of, and a no-penalty auto-cancel is a free
/// escape hatch from a match that is going badly, which is exactly the
/// dodge the doc's own abuse-safeguard item worries about. Warning the
/// player costs nothing when wrong and cannot be used to dodge.
library;

import 'dart:typed_data';

/// Mean luma, 0-255, from a YUV420 Y plane.
///
/// Sampled rather than summed in full: a 720x1280 frame is nearly a
/// million bytes and this runs on the UI isolate every few seconds. Every
/// 17th row and 7th pixel is plenty for an average and is ~1% of the
/// work. The strides are co-prime with typical widths so the sample does
/// not land on a single column.
int meanLuma(Uint8List yBuffer, {required int width, required int height,
    required int yStride}) {
  if (width <= 0 || height <= 0 || yBuffer.isEmpty) return 0;
  var total = 0;
  var count = 0;
  for (var row = 0; row < height; row += 17) {
    final base = row * yStride;
    for (var col = 0; col < width; col += 7) {
      final i = base + col;
      if (i >= yBuffer.length) break;
      total += yBuffer[i];
      count++;
    }
  }
  return count == 0 ? 0 : total ~/ count;
}

/// Below this mean luma a frame is too dark for anyone to read a face.
///
/// Chosen low on purpose. A dim room is fine and atmospheric; this is
/// meant to catch a lens cap, a pocket, or a genuinely unlit room. A
/// threshold that fired on "slightly dim" would nag people who are
/// perfectly visible, and a warning nobody needs is one they learn to
/// ignore.
const int kDarkLumaThreshold = 28;

/// Below this audio level a mic is producing nothing anyone can hear.
/// Matches the pre-match check's own bar, so a player who passed that
/// gate is not immediately told their mic is dead.
const int kQuietAudioThreshold = 8;

/// How many consecutive bad samples before saying anything.
///
/// A single dark frame means someone walked past the lens. Requiring a
/// run means the warning describes a STATE rather than a moment, which is
/// the difference between useful and twitchy.
const int kSustainedSamples = 3;

/// Tracks consecutive bad readings and reports when a problem is real.
///
/// Deliberately stateful and pure - no clock, no I/O - so the whole
/// escalation rule is testable without a camera.
class CaptureQualityMonitor {
  CaptureQualityMonitor({
    this.darkThreshold = kDarkLumaThreshold,
    this.quietThreshold = kQuietAudioThreshold,
    this.sustained = kSustainedSamples,
  });

  final int darkThreshold;
  final int quietThreshold;
  final int sustained;

  int _darkRun = 0;
  int _quietRun = 0;
  bool _darkReported = false;
  bool _quietReported = false;

  /// True at the moment a problem becomes sustained, and only then.
  bool get isDark => _darkRun >= sustained;
  bool get isQuiet => _quietRun >= sustained;

  /// Records a video sample. Returns a message to show, or null.
  ///
  /// Returns non-null EXACTLY ONCE per episode: it fires when the run
  /// first reaches the threshold and stays silent afterwards until the
  /// problem clears. Repeating it every few seconds during a battle
  /// would be worse than saying nothing.
  String? recordLuma(int luma) {
    if (luma < darkThreshold) {
      _darkRun++;
      if (_darkRun >= sustained && !_darkReported) {
        _darkReported = true;
        return 'Nobody can see you - your camera looks black.';
      }
      return null;
    }
    _darkRun = 0;
    _darkReported = false;
    return null;
  }

  /// Records an audio sample. Same once-per-episode rule.
  String? recordAudioLevel(int level) {
    if (level < quietThreshold) {
      _quietRun++;
      if (_quietRun >= sustained && !_quietReported) {
        _quietReported = true;
        return 'Nobody can hear you - check your mic.';
      }
      return null;
    }
    _quietRun = 0;
    _quietReported = false;
    return null;
  }

  /// A summary worth recording on the match, so an unwatchable clip can
  /// be deprioritised later and repeat offenders are visible.
  ///
  /// Counts EPISODES rather than samples, so one long blackout and one
  /// brief one are distinguishable from thirty consecutive dark frames.
  int darkEpisodes = 0;
  int quietEpisodes = 0;

  /// Call after each record* to accumulate the summary.
  void noteEpisode({required bool dark, required bool quiet}) {
    if (dark) darkEpisodes++;
    if (quiet) quietEpisodes++;
  }

  Map<String, Object?> get summary => {
        'darkEpisodes': darkEpisodes,
        'quietEpisodes': quietEpisodes,
      };
}
