import 'package:bully_league/core/battle_card.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('first fill is locked-change (starts the 30 days)', () {
    expect(isLockedChange('', 'San Diego'), isTrue);
  });
  test('a real change is a locked change', () {
    expect(isLockedChange('Mike', 'Michael'), isTrue);
  });
  test('saving the same value is not a change', () {
    expect(isLockedChange('Mike', ' Mike '), isFalse);
  });
  test('clearing is never blocked, but it is a clear', () {
    expect(isLockedChange('Mike', ''), isFalse);
    expect(isClearing('Mike', ''), isTrue);
    expect(isClearing('', ''), isFalse);
  });
  test('setup steps: intro + selfie always required, the rest asked once', () {
    final fresh = setupStepsNeeded({'profile': <String, dynamic>{}});
    expect(fresh, SetupStep.values);
    final done = setupStepsNeeded({
      'profile': {
        'rankedSetupDoneAt': 1,
        'facePhotoUrl': 'x',
        'introVideoUrl': '',
      },
    });
    expect(done, [SetupStep.intro]);
  });
}
