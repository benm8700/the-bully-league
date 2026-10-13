import 'package:flutter_test/flutter_test.dart';
import 'package:bully_league/core/judges_table.dart';

void main() {
  const base = 11;
  final panel = ['j1', 'j2', 'j3', 'j4', 'j5'];

  test('seats map to stable uids (base + index) in panel order', () {
    final seats = buildJudgeSeats(panel: panel, seatUidBase: base);
    expect(seats.length, 5);
    expect(seats[0].seatUid, 11);
    expect(seats[4].seatUid, 15);
    expect(seats.map((s) => s.judgeId).toList(), panel);
  });

  test('head judge and the viewing judge are marked', () {
    final seats = buildJudgeSeats(
        panel: panel, headJudge: 'j1', myUid: 'j3', seatUidBase: base);
    expect(seats[0].isHead, true);
    expect(seats[0].isMe, false);
    expect(seats[2].isMe, true);
    expect(seats[2].isHead, false);
    expect(seats.where((s) => s.isHead).length, 1);
  });

  test('a null viewer (the crowd) marks no seat as "me"', () {
    final seats = buildJudgeSeats(panel: panel, seatUidBase: base);
    expect(seats.any((s) => s.isMe), false);
  });

  test('each judge carries their own live vote, or null before they vote', () {
    final seats = buildJudgeSeats(
      panel: panel,
      seatUidBase: base,
      votes: {'j1': 'alice', 'j3': 'bob'},
    );
    expect(seats[0].votedFor, 'alice');
    expect(seats[1].votedFor, isNull);
    expect(seats[2].votedFor, 'bob');
  });

  test('the running tally counts only votes that have landed', () {
    expect(judgeVoteTally({}), <String, int>{});
    expect(
      judgeVoteTally({'j1': 'alice', 'j2': 'alice', 'j3': 'bob'}),
      {'alice': 2, 'bob': 1},
    );
  });

  test('a shorter panel (e.g. a dropout) still builds cleanly', () {
    final seats = buildJudgeSeats(panel: ['j1', 'j2'], seatUidBase: base);
    expect(seats.length, 2);
    expect(seats.last.seatUid, 12);
  });
}
