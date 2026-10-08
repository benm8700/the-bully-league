import 'package:flutter_test/flutter_test.dart';
import 'package:bully_league/core/emoji_ratings.dart';

void main() {
  group('emoji badge tiers mirror the server', () {
    // These MUST match BADGE_TIERS in functions/emojiRatings.js. If the server
    // changes a threshold, id or title, this test should be updated in lockstep
    // with the client constant - that is the whole point of pinning it.
    test('all four tracks, thresholds 10/50/150', () {
      expect(kEmojiBadgeTiers.keys.toList(),
          ['fire', 'clever', 'boring', 'trash', 'red_flag']);
      for (final key in kEmojiBadgeTiers.keys) {
        expect(kEmojiBadgeTiers[key]!.map((t) => t.at).toList(), [10, 50, 150],
            reason: key);
        expect(kEmojiBadgeTiers[key]!.map((t) => t.id).toList(),
            ['${key}_1', '${key}_2', '${key}_3'],
            reason: key);
      }
    });

    test('positives are gold, negatives are tarnished', () {
      expect(emojiIsPositive('fire'), isTrue);
      expect(emojiIsPositive('clever'), isTrue);
      expect(emojiIsPositive('boring'), isFalse);
      expect(emojiIsPositive('trash'), isFalse);
      expect(emojiIsPositive('red_flag'), isFalse);
    });
  });

  group('emojiBadgeSlots', () {
    test('no ratings: all four tracks locked at the first tier', () {
      final slots = emojiBadgeSlots(null);
      expect(slots.length, 5);
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

    test('negative emojis now produce (tarnished) badge slots', () {
      final slots = emojiBadgeSlots({'trash': 999, 'boring': 12});
      expect(slots.map((s) => s.emojiKey).toList(),
          ['fire', 'clever', 'boring', 'trash', 'red_flag']);
      final trash = slots.firstWhere((s) => s.emojiKey == 'trash');
      expect(trash.earnedTier!.id, 'trash_3'); // 999 → top tier
      expect(trash.isMaxed, isTrue);
      final boring = slots.firstWhere((s) => s.emojiKey == 'boring');
      expect(boring.earnedTier!.id, 'boring_1'); // 12 → first tier
    });
  });
}
