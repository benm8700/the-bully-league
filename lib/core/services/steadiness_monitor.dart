import 'dart:math';

/// Decides whether the phone is being held still enough for a good shot,
/// from accelerometer samples. Pure and clock-free so the rule is testable
/// without a device.
///
/// A propped phone is nearly motionless; a hand-held one carries a constant
/// micro-tremor plus breathing. We track how much the acceleration vector
/// CHANGES between consecutive samples - differencing cancels out gravity, so
/// the phone's orientation does not matter - and smooth it with an EMA. When
/// that smoothed jitter sits below a small threshold, the shot is steady.
///
/// Deliberately drives a NON-BLOCKING indicator only; it never gates the
/// Ready button. The pre-match mic gate already taught us (2026-09-01) that a
/// hard sensor gate strands real users - here it would be anyone on a couch
/// with nothing to prop against. We encourage steadiness, we don't demand it.
class SteadinessMonitor {
  SteadinessMonitor({
    this.threshold = 0.35, // m/s^2 of smoothed inter-sample change
    this.smoothing = 0.3, // EMA weight on the newest sample
  });

  /// Below this smoothed jitter the phone is treated as steady. A propped
  /// phone sits near zero; hand-held tremor comfortably clears it.
  final double threshold;

  /// How much a new sample moves the running average (0-1). Lower is calmer
  /// and slower to react; 0.3 settles within a second at ~16 Hz.
  final double smoothing;

  double? _px, _py, _pz;
  double _jitter = 0;
  bool _seeded = false;

  double get jitter => _jitter;

  /// Feeds one accelerometer sample (m/s^2, gravity included) and returns the
  /// current steady verdict.
  bool record(double x, double y, double z) {
    if (_px != null) {
      final d = sqrt(pow(x - _px!, 2) + pow(y - _py!, 2) + pow(z - _pz!, 2));
      _jitter = _seeded ? _jitter * (1 - smoothing) + d * smoothing : d;
      _seeded = true;
    }
    _px = x;
    _py = y;
    _pz = z;
    return isSteady;
  }

  /// True once there is enough signal to judge AND the jitter is low. Stays
  /// false before the first delta, so nothing claims "steady" before it has
  /// actually measured anything.
  bool get isSteady => _seeded && _jitter < threshold;
}
