import 'package:flutter_test/flutter_test.dart';

import 'package:bully_league/widgets/service_status_banner.dart';

/// The rules that decide whether a status notice is shown at all.
///
/// These are worth pinning because both failure directions are bad in
/// ways nobody would notice quickly. Showing nothing during a real outage
/// wastes the feature. Showing a STALE notice is worse: it makes a
/// working app look broken, and it teaches people to ignore the banner,
/// which costs you the one occasion it actually matters. The document is
/// hand-edited in the Firebase console with nothing validating it in
/// between, so every one of these cases is reachable by a typo.
void main() {
  final now = DateTime.utc(2026, 8, 17, 12);
  final ms = now.millisecondsSinceEpoch;

  ServiceStatus? parse(Map<String, dynamic>? m) => ServiceStatus.fromMap(m);

  group('nothing is shown when anything is ambiguous', () {
    test('a missing document shows nothing', () {
      expect(parse(null), isNull);
    });

    test('an inactive notice shows nothing', () {
      expect(parse({'active': false, 'message': 'x', 'updatedAtMs': ms}),
          isNull);
    });

    test('active must be literally true, not truthy', () {
      expect(parse({'active': 'yes', 'message': 'x', 'updatedAtMs': ms}),
          isNull);
      expect(parse({'active': 1, 'message': 'x', 'updatedAtMs': ms}), isNull);
    });

    test('an empty or whitespace message shows nothing', () {
      expect(parse({'active': true, 'message': '', 'updatedAtMs': ms}), isNull);
      expect(parse({'active': true, 'message': '   ', 'updatedAtMs': ms}),
          isNull);
    });

    test('a notice with no timestamp at all shows nothing', () {
      // Undateable means unexpirable, which is the one thing this must
      // never be. Treated as already expired rather than as fresh.
      expect(parse({'active': true, 'message': 'We are looking into it.'}),
          isNull);
    });
  });

  group('expiry', () {
    test('an explicit expiry in the future is live', () {
      final s = parse({
        'active': true,
        'message': 'Video is down. We know.',
        'expiresAtMs': ms + 3600 * 1000,
      });
      expect(s, isNotNull);
      expect(s!.isLiveAt(now), isTrue);
    });

    test('an explicit expiry in the past is not shown', () {
      final s = parse({
        'active': true,
        'message': 'Old news.',
        'expiresAtMs': ms - 1000,
      });
      expect(s!.isLiveAt(now), isFalse);
    });

    test('without an explicit expiry it lapses 24h after the last edit', () {
      final s = parse({
        'active': true,
        'message': 'Matchmaking is slow.',
        'updatedAtMs': ms,
      })!;
      expect(s.isLiveAt(now.add(const Duration(hours: 23))), isTrue);
      expect(s.isLiveAt(now.add(const Duration(hours: 25))), isFalse,
          reason: 'a notice left switched on must expire on its own');
    });

    test('an explicit expiry beats the default lifetime in both directions',
        () {
      final shorter = parse({
        'active': true,
        'message': 'Back in ten minutes.',
        'updatedAtMs': ms,
        'expiresAtMs': ms + 600 * 1000,
      })!;
      expect(shorter.isLiveAt(now.add(const Duration(hours: 1))), isFalse);

      final longer = parse({
        'active': true,
        'message': 'Maintenance all week.',
        'updatedAtMs': ms,
        'expiresAtMs': ms + 7 * 24 * 3600 * 1000,
      })!;
      expect(longer.isLiveAt(now.add(const Duration(days: 3))), isTrue);
    });
  });

  group('severity and message', () {
    test('a known severity is kept', () {
      for (final s in ['info', 'warning', 'outage']) {
        expect(parse({'active': true, 'message': 'x', 'severity': s,
          'updatedAtMs': ms})!.severity, s);
      }
    });

    test('severity is case-insensitive', () {
      expect(parse({'active': true, 'message': 'x', 'severity': 'OUTAGE',
        'updatedAtMs': ms})!.severity, 'outage');
    });

    test('an unknown severity falls back to info rather than being dropped',
        () {
      // A typo in the severity must not suppress a real outage notice -
      // the message is the part that matters.
      expect(parse({'active': true, 'message': 'x', 'severity': 'critical',
        'updatedAtMs': ms})!.severity, 'info');
      expect(parse({'active': true, 'message': 'x', 'updatedAtMs': ms})!
          .severity, 'info');
    });

    test('an overlong message is truncated rather than pushing the app '
        'off the screen', () {
      final long = 'a' * 500;
      final s = parse({'active': true, 'message': long, 'updatedAtMs': ms})!;
      expect(s.message.length, lessThan(long.length));
      expect(s.message.endsWith('...'), isTrue);
    });

    test('the message is trimmed', () {
      expect(parse({'active': true, 'message': '  Back soon.  ',
        'updatedAtMs': ms})!.message, 'Back soon.');
    });
  });
}
