import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:bully_league/core/services/career_track.dart';

/// The career ladder is implemented twice - here and in
/// functions/careerTrack.js - because the client needs it for a progress
/// bar and the server needs it for anything it later computes. Two
/// implementations of one ladder can drift, and the symptom would be a
/// player shown one title in the app and recorded as another, which
/// nothing else would surface. So the last test reads the server's own
/// table and asserts they agree, rather than trusting a comment.
void main() {
  group('career standing', () {
    test('a brand-new account has a title, not a blank', () {
      final s = CareerStanding.fromPoints(0);
      expect(s.title, 'Walk-In');
      expect(s.tier, 0);
    });

    test('a title is earned exactly at its threshold', () {
      expect(CareerStanding.fromPoints(250).title, 'Two-Drink Minimum');
      expect(CareerStanding.fromPoints(249).title, 'Walk-In');
    });

    test('progress runs 0..1 through the current band', () {
      expect(CareerStanding.fromPoints(750).progress, closeTo(0, 1e-9));
      expect(CareerStanding.fromPoints(1125).progress, closeTo(0.5, 1e-9));
    });

    test('the top title has nothing left to fill toward', () {
      final top = CareerStanding.fromPoints(999999);
      expect(top.nextTitle, isNull);
      expect(top.pointsToNext, isNull);
      expect(top.progress, isNull);
    });

    test('null and negative points degrade to a valid standing', () {
      for (final points in <num?>[null, -500]) {
        final s = CareerStanding.fromPoints(points);
        expect(s.points, 0);
        expect(s.title, 'Walk-In');
      }
    });

    test('pointsToNext counts down honestly', () {
      final s = CareerStanding.fromPoints(700);
      expect(s.nextTitle, 'Road Dog');
      expect(s.pointsToNext, 50);
    });

    test('MIRROR: the ladder matches the server, title for title', () {
      // Parsed out of the server module rather than duplicated here, so
      // this fails if either side is edited alone.
      final source =
          File('functions/careerTrack.js').readAsStringSync();
      final block = RegExp(r'const CAREER_TITLES = \[(.*?)\];', dotAll: true)
          .firstMatch(source);
      expect(block, isNotNull, reason: 'could not find CAREER_TITLES');
      final entries = RegExp(r'threshold:\s*(\d+),\s*title:\s*"([^"]+)"')
          .allMatches(block!.group(1)!)
          .map((m) => (int.parse(m.group(1)!), m.group(2)!))
          .toList();

      expect(entries.length, careerTitles.length,
          reason: 'the two ladders have different numbers of titles');
      for (var i = 0; i < entries.length; i++) {
        expect(careerTitles[i].threshold, entries[i].$1,
            reason: 'threshold ${i} differs from the server');
        expect(careerTitles[i].title, entries[i].$2,
            reason: 'title ${i} differs from the server');
      }
      // Guards against the regex silently matching nothing and the test
      // passing on two empty lists.
      expect(entries.length, greaterThan(3));
      expect(jsonEncode(entries.map((e) => e.$2).toList()),
          contains('Walk-In'));
    });
  });
}
