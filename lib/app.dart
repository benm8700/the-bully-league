import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'core/services/age_verification_service.dart';
import 'core/services/auth_service.dart';
import 'screens/auth/signup_screen.dart';
import 'screens/home/home_screen.dart';
import 'screens/moderation/banned_screen.dart';

class BullyLeagueApp extends StatelessWidget {
  const BullyLeagueApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        Provider<AuthService>(create: (_) => AuthService(FirebaseAuth.instance)),
        Provider<AgeVerificationService>(create: (_) => StubAgeVerificationService()),
      ],
      child: MaterialApp(
        title: 'The Bully League',
        themeMode: ThemeMode.dark,
        darkTheme: ThemeData.dark(useMaterial3: true),
        theme: ThemeData(useMaterial3: true),
        home: const AuthGate(),
      ),
    );
  }
}

class AuthGate extends StatelessWidget {
  const AuthGate({super.key});

  @override
  Widget build(BuildContext context) {
    final authService = context.read<AuthService>();

    return StreamBuilder<User?>(
      stream: authService.authStateChanges(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Scaffold(body: Center(child: CircularProgressIndicator()));
        }
        if (snapshot.hasData) {
          return _AccountStatusGate(uid: snapshot.data!.uid);
        }
        return const SignupScreen();
      },
    );
  }
}

/// Gates HomeScreen behind the signed-in user's accountStatus - a banned
/// account sees BannedScreen (with its appeal flow) instead, per CLAUDE.md's
/// Trust & Safety / Ban appeal decision. accountStatus is set once at
/// signup and only an admin (Firebase console, Admin SDK) can change it
/// after that - see firestore.rules and CLAUDE.md's Security & Compliance
/// Baseline - so there's no client-side way to write past this gate.
class _AccountStatusGate extends StatelessWidget {
  const _AccountStatusGate({required this.uid});

  final String uid;

  @override
  Widget build(BuildContext context) {
    final userRef = FirebaseFirestore.instance.collection('users').doc(uid);
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: userRef.snapshots(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Scaffold(body: Center(child: CircularProgressIndicator()));
        }
        final accountStatus = snapshot.data?.data()?['accountStatus'] as String?;
        if (accountStatus == 'banned') {
          return const BannedScreen();
        }
        return const HomeScreen();
      },
    );
  }
}
