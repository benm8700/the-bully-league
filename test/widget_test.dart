import 'package:bully_league/core/services/age_verification_service.dart';
import 'package:bully_league/screens/auth/signup_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

void main() {
  testWidgets('Signup opens on step 1 of 4: just the username',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Provider<AgeVerificationService>(
          create: (_) => StubAgeVerificationService(),
          child: const SignupScreen(),
        ),
      ),
    );

    expect(find.text('Step 1 of 4'), findsOneWidget);
    expect(find.text('Pick your username'), findsOneWidget);
    expect(find.widgetWithText(TextFormField, 'Username'), findsOneWidget);
    // Later steps are not on screen yet.
    expect(find.widgetWithText(TextFormField, 'Email'), findsNothing);
    expect(find.widgetWithText(TextFormField, 'Password'), findsNothing);
    expect(find.widgetWithText(FilledButton, 'Next'), findsOneWidget);
  });
}
