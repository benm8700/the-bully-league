import 'package:bully_league/app.dart' show kActiveTheme;
import 'package:bully_league/theme/app_theme.dart';
import 'package:bully_league/widgets/match/battle_scorebug.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The scorebug must lay out in every mood on a narrow phone, with a long
/// opponent name, without overflowing (the show overhaul, 2026-11-12).
void main() {
  for (final width in [320.0, 360.0, 430.0]) {
    for (final mood in PlateMood.values) {
      testWidgets('scorebug $mood at ${width.toInt()}', (tester) async {
        tester.view.physicalSize = Size(width * 3, 2400);
        tester.view.devicePixelRatio = 3;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          MaterialApp(
            theme: appTheme(kActiveTheme.value),
            home: Scaffold(
              body: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Column(
                  children: [
                    BattleScorebug(
                      oppName: 'TheRoastMasterGenerl',
                      myMs: 24000,
                      oppMs: 30000,
                      totalMs: 30000,
                      myMood: mood,
                      oppLive: mood == PlateMood.idle,
                      warningValue: 'PASSING IN 3',
                      mySteals: 1,
                      oppSteals: 2,
                      totalSteals: 2,
                    ),
                    const WarmupRing(seconds: 12, total: 15),
                    const EndStamp(text: 'DEAD AIR'),
                  ],
                ),
              ),
            ),
          ),
        );
        await tester.pump(const Duration(seconds: 1));
        expect(tester.takeException(), isNull);
      });
    }
  }
}
