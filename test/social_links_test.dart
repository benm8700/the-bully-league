import 'package:bully_league/core/social_links.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('normalizeSocialValue - handles', () {
    test('strips a leading @ and whitespace', () {
      expect(normalizeSocialValue('instagram', '  @funnyguy '), 'funnyguy');
    });
    test('accepts a bare handle', () {
      expect(normalizeSocialValue('tiktok', 'funny.guy_1'), 'funny.guy_1');
    });
    test('pulls the handle out of a pasted profile URL', () {
      expect(normalizeSocialValue('instagram', 'https://instagram.com/funnyguy'),
          'funnyguy');
      expect(normalizeSocialValue('x', 'x.com/@funnyguy'), 'funnyguy');
    });
    test('rejects junk and spaces', () {
      expect(normalizeSocialValue('instagram', 'not a handle'), isNull);
      expect(normalizeSocialValue('instagram', ''), isNull);
      expect(normalizeSocialValue('instagram', '@'), isNull);
    });
  });

  group('normalizeSocialValue - urls', () {
    test('adds https:// when no scheme is given', () {
      expect(normalizeSocialValue('website', 'mysite.com'),
          'https://mysite.com');
    });
    test('keeps an explicit https URL', () {
      expect(normalizeSocialValue('tickets', 'https://shows.com/me'),
          'https://shows.com/me');
    });
    test('rejects a non-http scheme', () {
      expect(normalizeSocialValue('website', 'javascript:alert(1)'), isNull);
      expect(normalizeSocialValue('website', 'ftp://x.com'), isNull);
    });
    test('rejects a host with no dot', () {
      expect(normalizeSocialValue('website', 'localhost'), isNull);
    });
  });

  group('socialUrl', () {
    test('builds the right link per platform', () {
      expect(socialUrl('instagram', 'funnyguy'),
          'https://instagram.com/funnyguy');
      expect(socialUrl('tiktok', 'funnyguy'),
          'https://www.tiktok.com/@funnyguy');
      expect(socialUrl('youtube', 'funnychan'),
          'https://www.youtube.com/@funnychan');
      expect(socialUrl('x', 'funnyguy'), 'https://x.com/funnyguy');
      expect(socialUrl('website', 'https://mysite.com'), 'https://mysite.com');
    });
  });

  group('socialLinksOf', () {
    test('reads known platforms with non-empty values', () {
      final links = socialLinksOf({
        'profile': {
          'links': {'instagram': 'funnyguy', 'tiktok': '  ', 'bogus': 'x'},
        },
      });
      expect(links, {'instagram': 'funnyguy'});
    });
    test('empty/absent is an empty map', () {
      expect(socialLinksOf(null), isEmpty);
      expect(socialLinksOf({'profile': {}}), isEmpty);
    });
  });
}
