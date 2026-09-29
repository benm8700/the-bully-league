import 'package:flutter_test/flutter_test.dart';
import 'package:bully_league/core/emoji_ratings.dart';

void main() {
  group('emoji badge tiers mirror the server', () {
    // These MUST match BADGE_TIERS in functions/emojiRatings.js. If the server
    // changes a threshold, id or title, this test should be updated in lockstep
    // with the client constant - that is the whole point of pinning it.
    test('fire and clever tracks, thresholds 10/50/150', () {
      expect(kEmojiBadgeTiers.keys.toList(), ['fire', 'clever']);
      expect(kEmojiBadgeTiers['fire']!.map((t) => t.at).toList(), [10, 50, 150]);
      expect(kEmojiBadgeTiers['clever']!.map((t) => t.at).toList(),
          [10, 50, 150]);
      expect(kEmojiBadgeTiers['fire']!.map((t) => t.id).toList(),
          ['fire_1', 'fire_2', 'fire_3']);
      expect(kEmojiBadgeTiers['clever']!.map((t) => t.id).toList(),
          ['clever_1', 'clever_2', 'clever_3']);
    });

    test('only the two POSITIVE emojis have badges', () {
      expect(kEmojiBadgeTiers.containsKey('boring'), isFalse);
      expect(kEmojiBadgeTiers.containsKey('trash'), isFalse);
    });
  });

  group('emojiBadgeSlots', () {
    test('no ratings: both tracks locked at the first tier', () {
      final slots = emojiBadgeSlots(null);
      expect(slots.length, 2);
      for (final s in slots) {
        expect(s.earned, isFalse);
        expect(s.count, 0);
        expect(s.isMaxed, isFalse);
        expect(s.nextTier!.at, 10);
        expect(s.displayTier.at, 10); // shows the first (locked) tier
      }
    });

    test('exactly at a threshold earns that tier', () {
      final fire = emojiBadgeSlots({'fire': 10}).first;
      expect(fire.earned, isTrue);
      expect(fire.earnedTier!.id, 'fire_1');
      expect(fire.nextTier!.at, 50);
      expect(fire.isMaxed, isFalse);
    });

    test('just below a threshold does not earn the next tier', () {
      final fire = emojiBadgeSlots({'fire': 49}).first;
      expect(fire.earnedTier!.id, 'fire_1');
      expect(fire.nextTier!.at, 50);
    });

    test('top tier: earned and maxed, no next tier', () {
      final fire = emojiBadgeSlots({'fire': 150}).first;
      expect(fire.earnedTier!.id, 'fire_3');
      expect(fire.isMaxed, isTrue);
      expect(fire.nextTier, isNull);
    });

    test('tracks are independent', () {
      final slots = emojiBadgeSlots({'fire': 60});
      final fire = slots.firstWhere((s) => s.emojiKey == 'fire');
      final clever = slots.firstWhere((s) => s.emojiKey == 'clever');
      expect(fire.earnedTier!.id, 'fire_2');
      expect(clever.earned, isFalse);
    });

    test('negative emojis never produce a badge slot', () {
      final keys = emojiBadgeSlots({'trash': 999, 'boring': 999})
          .map((s) => s.emojiKey)
          .toList();
      expect(keys, ['fire', 'clever']);
    });
  });
}
