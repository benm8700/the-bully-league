import 'package:bully_league/app.dart' show kActiveTheme;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:bully_league/core/main_stage_battle.dart';
import 'package:bully_league/theme/app_theme.dart';
import 'package:bully_league/widgets/match/watch_strip.dart';

Widget _wrap(Widget w, double width) => MaterialApp(
  theme: appTheme(kActiveTheme.value),
  home: Scaffold(
    body: Center(
      child: SizedBox(width: width, child: w),
    ),
  ),
);

MainStageBattleState _rounds({String first = 'a'}) {
  var b = MainStageBattleState.create([
    'a',
    'b',
  ], config: const MainStageBattleConfig(turnMs: 15000, turnCount: 6));
  b = b.reduce(MsEvent.open, by: first, atMs: 0);
  return b;
}

MainStageBattleState _lastWord() {
  var b = MainStageBattleState.create([
    'a',
    'b',
  ], config: const MainStageBattleConfig(turnMs: 15000, turnCount: 2));
  b = b.reduce(MsEvent.open, by: 'a', atMs: 0);
  return b.reduce(MsEvent.yield, by: 'a', atMs: 1000);
}

void main() {
  for (final width in [320.0, 390.0, 430.0]) {
    testWidgets('countdown fits at $width', (t) async {
      await t.pumpWidget(
        _wrap(
          const WatchStrip(state: null, topId: 'a', startsInSeconds: 12),
          width,
        ),
      );
      expect(find.text('STARTS IN'), findsOneWidget);
      expect(t.takeException(), isNull);
    });

    testWidgets('rapid rounds: top player speaking at $width', (t) async {
      await t.pumpWidget(
        _wrap(WatchStrip(state: _rounds(), topId: 'a'), width),
      );
      expect(find.text('0:15'), findsOneWidget);
      expect(find.byIcon(Icons.keyboard_arrow_up), findsNothing);
      expect(find.textContaining('1/3'), findsOneWidget);
      expect(t.takeException(), isNull);
    });

    testWidgets('rapid rounds: bottom player speaking at $width', (t) async {
      await t.pumpWidget(
        _wrap(
          WatchStrip(
            state: _rounds(first: 'b'),
            topId: 'a',
          ),
          width,
        ),
      );
      expect(find.text('0:15'), findsOneWidget);
      expect(t.takeException(), isNull);
    });

    testWidgets('main stage chess clocks at $width', (t) async {
      var b = MainStageBattleState.create(['a', 'b']);
      b = b.reduce(MsEvent.open, by: 'a', atMs: 0);
      await t.pumpWidget(
        _wrap(WatchStrip(state: b, topId: 'a', mainStage: true), width),
      );
      expect(find.text('1:00'), findsNWidgets(2));
      expect(find.text('#1'), findsNothing); // ranks live on the video now
      expect(t.takeException(), isNull);
    });
  }

  testWidgets('main stage: the logo always gets its full slot', (t) async {
    var b = MainStageBattleState.create(['a', 'b']);
    b = b.reduce(MsEvent.open, by: 'a', atMs: 0);
    await t.pumpWidget(
      _wrap(WatchStrip(state: b, topId: 'a', mainStage: true), 320),
    );
    expect(t.takeException(), isNull);
    final logo = find.bySemanticsLabel('The Bully League');
    expect(logo, findsOneWidget);
    expect(t.getSize(find.byType(Image).last).width, 64);
  });

  testWidgets('last word shows in the clock pill', (t) async {
    final b = _lastWord();
    await t.pumpWidget(_wrap(WatchStrip(state: b, topId: 'a'), 320));
    expect(b.isLastTurn, isTrue);
    expect(find.text('LAST WORD'), findsOneWidget);
    expect(t.takeException(), isNull);
  });

  test('battle kind labels', () {
    expect(battleKindLabel('ranked'), 'RANKED');
    expect(battleKindLabel('friend'), 'ROAST A FRIEND');
    expect(battleKindLabel('improv'), 'FACE-OFF');
    expect(
      battleKindLabel('tournament', mainStageRound: 'SEMI-FINAL'),
      'MAIN STAGE · SEMI-FINAL',
    );
    expect(
      battleKindLabel('tournament', mainStageRound: 'FINAL'),
      'MAIN STAGE · FINAL',
    );
    expect(battleKindLabel(null), 'RANKED');
  });
}
