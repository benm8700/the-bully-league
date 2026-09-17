import 'dart:math';

import 'package:bully_league/core/services/steadiness_monitor.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SteadinessMonitor', () {
    test('is not steady before it has measured a delta', () {
      final m = SteadinessMonitor();
      expect(m.record(0, 0, 9.8), isFalse); // first sample, no delta yet
    });

    test('a motionless phone reads steady', () {
      final m = SteadinessMonitor();
      // A propped phone: the same gravity vector every sample.
      bool steady = false;
      for (var i = 0; i < 20; i++) {
        steady = m.record(0.01, -0.02, 9.79);
      }
      expect(steady, isTrue);
      expect(m.jitter, lessThan(m.threshold));
    });

    test('a hand-held tremor reads not steady', () {
      final m = SteadinessMonitor();
      final rnd = Random(1);
      bool steady = true;
      for (var i = 0; i < 40; i++) {
        // Continuous jitter well above the threshold on each axis.
        steady = m.record(
          0.6 * (rnd.nextDouble() - 0.5) * 2,
          0.6 * (rnd.nextDouble() - 0.5) * 2,
          9.8 + 0.6 * (rnd.nextDouble() - 0.5) * 2,
        );
      }
      expect(steady, isFalse);
      expect(m.jitter, greaterThan(m.threshold));
    });

    test('settles back to steady once motion stops', () {
      final m = SteadinessMonitor();
      final rnd = Random(2);
      for (var i = 0; i < 20; i++) {
        m.record(rnd.nextDouble(), rnd.nextDouble(), 9.8 + rnd.nextDouble());
      }
      expect(m.isSteady, isFalse);
      bool steady = false;
      for (var i = 0; i < 20; i++) {
        steady = m.record(0.0, 0.0, 9.8);
      }
      expect(steady, isTrue);
    });
  });
}
