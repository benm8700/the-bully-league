import 'package:bully_league/core/contact_hash.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('normalises like the server', () {
    expect(normalizeE164('(650) 555-1235'), '+16505551235');
    expect(normalizeE164('1 650 555 1235'), '+16505551235');
    expect(normalizeE164('+44 20 7946 0958'), '+442079460958');
    expect(normalizeE164('555-1235'), isNull);
    expect(normalizeE164('12345678901234567'), isNull);
  });

  test('hash matches functions/test/contactMatch.test.js', () {
    expect(
      phoneHash('+16505551235'),
      '9c416fef0b6f2137a2c8cd341f839e36ee4e3fa2bca0b553c68fbe56e0b8f69c',
    );
  });
}
