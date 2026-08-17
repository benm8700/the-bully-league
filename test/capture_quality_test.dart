import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:bully_league/core/services/capture_quality.dart';

/// A Y plane filled with one value, which is what a lens cap or a blank
/// wall effectively produces.
Uint8List flatPlane(int value, {int width = 64, int height = 64}) =>
    Uint8List.fromList(List.filled(width * height, value));

void main() {
  group('meanLuma', () {
    test('a black frame reads as black', () {
      expect(meanLuma(flatPlane(0), width: 64, height: 64, yStride: 64), 0);
    });

    test('a bright frame reads as bright', () {
      expect(meanLuma(flatPlane(200), width: 64, height: 64, yStride: 64),
          200);
    });

    test('sampling still lands near the true mean on a gradient', () {
      // Sampling every 17th row and 7th pixel must not bias the result -
      // a threshold judged on a skewed average would fire on frames that
      // are perfectly visible.
      const w = 128;
      const h = 128;
      final plane = Uint8List(w * h);
      for (var row = 0; row < h; row++) {
        for (var col = 0; col < w; col++) {
          plane[row * w + col] = (row * 2) % 256;
        }
      }
      final mean = meanLuma(plane, width: w, height: h, yStride: w);
      expect(mean, closeTo(127, 20));
    });

    test('respects stride rather than assuming width', () {
      // Agora frames are commonly padded. Reading row-by-row at `width`
      // would drift across the image and average the wrong pixels.
      const w = 32;
      const h = 8;
      const stride = 48;
      final plane = Uint8List(stride * h);
      for (var row = 0; row < h; row++) {
        for (var col = 0; col < stride; col++) {
          // Real pixels bright, padding black.
          plane[row * stride + col] = col < w ? 200 : 0;
        }
      }
      expect(meanLuma(plane, width: w, height: h, yStride: stride), 200);
    });

    test('degrades safely on nonsense input', () {
      expect(meanLuma(Uint8List(0), width: 10, height: 10, yStride: 10), 0);
      expect(meanLuma(flatPlane(100), width: 0, height: 0, yStride: 0), 0);
    });

    test('never reads past the end of a short buffer', () {
      final short = Uint8List.fromList(List.filled(10, 255));
      expect(() => meanLuma(short, width: 640, height: 480, yStride: 640),
          returnsNormally);
    });
  });

  group('CaptureQualityMonitor', () {
    test('ONE dark frame says nothing - somebody walked past the lens', () {
      final m = CaptureQualityMonitor();
      expect(m.recordLuma(0), isNull);
      expect(m.isDark, isFalse);
    });

    test('a SUSTAINED blackout is reported', () {
      final m = CaptureQualityMonitor();
      String? message;
      for (var i = 0; i < kSustainedSamples; i++) {
        message = m.recordLuma(0);
      }
      expect(message, isNotNull);
      expect(message, contains('see you'));
      expect(m.isDark, isTrue);
    });

    test('REPORTED ONCE per episode, not every few seconds', () {
      // Repeating the same warning throughout a battle would be worse
      // than never saying it.
      final m = CaptureQualityMonitor();
      for (var i = 0; i < kSustainedSamples; i++) {
        m.recordLuma(0);
      }
      for (var i = 0; i < 10; i++) {
        expect(m.recordLuma(0), isNull, reason: 'repeated at sample $i');
      }
    });

    test('recovering resets, so a LATER blackout is reported again', () {
      final m = CaptureQualityMonitor();
      for (var i = 0; i < kSustainedSamples; i++) {
        m.recordLuma(0);
      }
      m.recordLuma(180); // lights back on
      expect(m.isDark, isFalse);
      String? second;
      for (var i = 0; i < kSustainedSamples; i++) {
        second = m.recordLuma(0);
      }
      expect(second, isNotNull);
    });

    test('a dim but visible room is NOT flagged', () {
      // The threshold exists to catch a lens cap or an unlit room, not to
      // nag someone who is perfectly visible in low light. A warning
      // nobody needs is one they learn to ignore.
      final m = CaptureQualityMonitor();
      for (var i = 0; i < 20; i++) {
        expect(m.recordLuma(kDarkLumaThreshold + 5), isNull);
      }
      expect(m.isDark, isFalse);
    });

    test('a dead mic is reported on the same sustained rule', () {
      final m = CaptureQualityMonitor();
      expect(m.recordAudioLevel(0), isNull);
      m.recordAudioLevel(0);
      final message = m.recordAudioLevel(0);
      expect(message, contains('hear you'));
    });

    test('normal speech never trips the mic warning', () {
      final m = CaptureQualityMonitor();
      for (var i = 0; i < 20; i++) {
        expect(m.recordAudioLevel(kQuietAudioThreshold + 20), isNull);
      }
    });

    test('video and audio runs are independent', () {
      // A dark frame must not count toward a mic problem or vice versa.
      final m = CaptureQualityMonitor();
      for (var i = 0; i < 5; i++) {
        m.recordLuma(0);
      }
      expect(m.isQuiet, isFalse);
    });

    test('the summary counts episodes for later ranking', () {
      final m = CaptureQualityMonitor();
      m.noteEpisode(dark: true, quiet: false);
      m.noteEpisode(dark: true, quiet: true);
      expect(m.summary['darkEpisodes'], 2);
      expect(m.summary['quietEpisodes'], 1);
    });
  });
}
