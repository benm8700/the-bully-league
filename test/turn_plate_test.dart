import 'package:bully_league/app.dart' show kActiveTheme;
import 'package:bully_league/theme/app_theme.dart';
import 'package:bully_league/widgets/match/turn_plate.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The rapid-rounds plate shares the top of the screen with the selfie, so on
/// a 320px phone it is only ~214px wide. Every mood, with the full name /
/// city / country stack and a long label, must lay out without overflowing.
void main() {
  // Plate width = screen - 4 - selfie 92 - 6 - 4.
  for (final width in [214.0, 254.0, 324.0]) {
    for (final mood in TurnMood.values) {
      for (final squeeze in [false, true]) {
        testWidgets('plate $mood squeeze=$squeeze at ${width.toInt()}', (
          tester,
        ) async {
          tester.view.physicalSize = const Size(1200, 2400);
          tester.view.devicePixelRatio = 3;
          addTearDown(tester.view.reset);
          await tester.pumpWidget(
            MaterialApp(
              theme: appTheme(kActiveTheme.value),
              home: Scaffold(
                body: Align(
                  alignment: Alignment.topLeft,
                  child: SizedBox(
                    width: width,
                    child: Column(
                      children: [
                        TurnPlate(
                          label: 'THEROASTMASTERGENERL · ON THE MIC',
                          clockMs: 11000,
                          totalMs: 15000,
                          round: 2,
                          roundCount: 3,
                          mood: mood,
                          lines: const [
                            'vs Bartholomew',
                            'Rancho Santa Margarita, California',
                            'United States',
                          ],
                          squeeze: squeeze,
                          pulse: 0.5,
                          warnFill: 0.5,
                        ),
                        const SizedBox(
                          height: 300,
                          child: MicFlash(mine: true, sub: 'ROUND 2 · GO'),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pump(const Duration(milliseconds: 400));
          expect(tester.takeException(), isNull);
        });
      }
    }
  }
}
