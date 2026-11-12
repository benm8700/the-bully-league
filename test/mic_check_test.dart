import 'package:flutter_test/flutter_test.dart';
import 'package:bully_league/core/services/mic_check.dart';

void main() {
  // Feeds reports 200ms apart, returning the final phase.
  MicPhase feed(MicCheck m, List<(int, bool)> reports, {int startMs = 0}) {
    var t = startMs;
    var p = m.phase;
    for (final (level, voice) in reports) {
      p = m.add(level: level, voice: voice, nowMs: t);
      t += 200;
    }
    return p;
  }

  final quietRoom = List.filled(9, (3, false)); // 1.6s of quiet
  const phrase = [(30, true), (34, true), (28, true), (20, false)];

  test('quiet room, then "The Bully League", passes first time', () {
    final m = MicCheck();
    expect(feed(m, quietRoom), MicPhase.speak);
    expect(m.roomQuiet, isTrue);
    expect(feed(m, phrase, startMs: 2000), MicPhase.passed);
  });

  test('noise BEFORE the speak step cannot pass it', () {
    final m = MicCheck();
    // Someone talks loudly during the room step...
    final loudRoom = List.filled(9, (35, true));
    expect(feed(m, loudRoom), MicPhase.tooNoisy);
    expect(m.passed, isFalse);
  });

  test('a TV in the background fails the room check, then recovers', () {
    final m = MicCheck();
    final tv = [for (var i = 0; i < 9; i++) (14 + (i * 7) % 9, true)];
    expect(feed(m, tv), MicPhase.tooNoisy);
    expect(m.roomQuiet, isFalse);
    // TV turned down: the next room measurement passes.
    expect(feed(m, quietRoom, startMs: 2000), MicPhase.speak);
  });

  test('a slightly noisy-but-ok room raises the bar', () {
    final m = MicCheck();
    feed(m, List.filled(9, (10, false))); // room 10 -> bar 22
    expect(m.bar, 22);
    // Talking at 18 is not clearly above the room.
    expect(feed(m, List.filled(4, (18, true)), startMs: 2000), MicPhase.speak);
    expect(feed(m, phrase, startMs: 3000), MicPhase.passed);
  });

  test('shouting / right on the mic does not count and says too loud', () {
    final m = MicCheck();
    feed(m, quietRoom);
    expect(feed(m, List.filled(4, (230, true)), startMs: 2000), MicPhase.speak);
    expect(m.tooLoudAt(2700), isTrue);
  });

  test('a single short blip is not enough', () {
    final m = MicCheck();
    feed(m, quietRoom);
    expect(feed(m, [(30, true), (2, false), (2, false), (2, false)],
        startMs: 2000), MicPhase.speak);
  });

  test('loud non-voice sound (a clap) never counts', () {
    final m = MicCheck();
    feed(m, quietRoom);
    expect(feed(m, List.filled(6, (60, false)), startMs: 2000), MicPhase.speak);
  });
}
