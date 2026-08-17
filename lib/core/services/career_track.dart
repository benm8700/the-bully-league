import 'package:flutter/foundation.dart';

/// The career track: a second ladder built on points rather than rating.
///
/// MIRRORS functions/careerTrack.js and must stay in step with it - a
/// player shown one title in the app and recorded as another server-side
/// would be a difference nothing surfaces. Kept client-side because it is
/// pure arithmetic over a number the client already has, so a round trip
/// would buy nothing.
///
///   rank title   = how good you are RIGHT NOW      (skill, can be lost)
///   career title = everything you have EVER DONE   (mileage, permanent)
///
/// Rating goes down, which is what makes it meaningful and also what makes
/// it punishing. Career points only rise, so someone mid-losing-streak
/// still has a number moving the right way.
@immutable
class CareerTitle {
  const CareerTitle(this.threshold, this.title);
  final int threshold;
  final String title;
}

/// PLACEHOLDER thresholds, mirroring the server's. See careerTrack.js.
const careerTitles = <CareerTitle>[
  CareerTitle(0, 'Walk-In'),
  CareerTitle(250, 'Two-Drink Minimum'),
  CareerTitle(750, 'Road Dog'),
  CareerTitle(1500, 'Late Set'),
  CareerTitle(3000, 'Every Night'),
  CareerTitle(6000, 'Lifer'),
  CareerTitle(12000, 'Institution'),
];

@immutable
class CareerStanding {
  const CareerStanding({
    required this.points,
    required this.title,
    required this.tier,
    required this.nextTitle,
    required this.pointsToNext,
    required this.progress,
  });

  final int points;
  final String title;
  final int tier;
  final String? nextTitle;
  final int? pointsToNext;

  /// 0..1 through the current band, or null at the top.
  final double? progress;

  /// Reads the CAREER total, never the spendable balance: buying a clip
  /// must never cost someone a title. That separation is the whole reason
  /// the two numbers exist.
  factory CareerStanding.fromPoints(num? rawPoints) {
    final points = (rawPoints ?? 0).toInt().clamp(0, 1 << 62);
    var index = 0;
    for (var i = 0; i < careerTitles.length; i++) {
      if (points >= careerTitles[i].threshold) index = i;
    }
    final current = careerTitles[index];
    final next = index + 1 < careerTitles.length ? careerTitles[index + 1] : null;
    return CareerStanding(
      points: points,
      title: current.title,
      tier: index,
      nextTitle: next?.title,
      pointsToNext: next == null ? null : next.threshold - points,
      progress: next == null
          ? null
          : (points - current.threshold) /
              (next.threshold - current.threshold),
    );
  }
}
