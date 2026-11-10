import 'package:bully_league/core/services/age_verification_service.dart';
import 'package:bully_league/screens/auth/signup_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

void main() {
  testWidgets('Signup opens on the 18+ screen, then step 1 is the username',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
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

    await tester.tap(find.widgetWithText(FilledButton, "I'm 18 or older"));
    await tester.pumpAndSettle();

    expect(find.text('Step 1 of 4'), findsOneWidget);
    expect(find.text('Pick your username'), findsOneWidget);
    expect(find.widgetWithText(TextFormField, 'Username'), findsOneWidget);
    expect(find.widgetWithText(TextFormField, 'Email'), findsNothing);
    expect(find.widgetWithText(FilledButton, 'Next'), findsOneWidget);
  });
}
