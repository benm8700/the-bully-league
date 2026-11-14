import 'package:bully_league/app.dart' show kActiveTheme;
import 'package:bully_league/core/services/age_verification_service.dart';
import 'package:bully_league/theme/app_theme.dart';
import 'package:bully_league/widgets/neon_action_button.dart';
import 'package:bully_league/screens/auth/signup_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

void main() {
  testWidgets('Signup opens on the 18+ screen, then step 1 is the username',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(kActiveTheme.value),
        home: Provider<AgeVerificationService>(
          create: (_) => StubAgeVerificationService(),
          child: const SignupScreen(),
        ),
      ),
    );

    // First: our own 18+ screen, before any form or native age prompt.
    expect(find.text('You must be 18+'), findsOneWidget);
    expect(find.text('Step 1 of 4'), findsNothing);
    expect(find.widgetWithText(TextFormField, 'Username'), findsNothing);

    await tester.tap(find.widgetWithText(NeonActionButton, "I'M 18 OR OLDER"));
    await tester.pumpAndSettle();

    expect(find.text('Step 1 of 4'), findsOneWidget);
    expect(find.text('Pick your username'), findsOneWidget);
    expect(find.widgetWithText(TextFormField, 'Username'), findsOneWidget);
    expect(find.widgetWithText(TextFormField, 'Email'), findsNothing);
    expect(find.widgetWithText(NeonActionButton, 'NEXT'), findsOneWidget);
  });
}
