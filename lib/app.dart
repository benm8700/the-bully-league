import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'core/services/age_verification_service.dart';
import 'core/services/auth_service.dart';
import 'core/services/cloud_vision_moderation_service.dart';
import 'core/services/push_notification_service.dart';
import 'core/services/visual_moderation_service.dart';
import 'screens/auth/signup_screen.dart';
import 'screens/home/main_shell.dart';
import 'screens/moderation/banned_screen.dart';

class BullyLeagueApp extends StatelessWidget {
  const BullyLeagueApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        Provider<AuthService>(create: (_) => AuthService(FirebaseAuth.instance)),
        Provider<AgeVerificationService>(create: (_) => StubAgeVerificationService()),
        Provider<VisualModerationService>(create: (_) => CloudVisionModerationService()),
        Provider<PushNotificationService>(create: (_) => PushNotificationService()),
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
          // Keyed by uid so signing in as a different account builds a
          // fresh State - otherwise Flutter reuses the element and the new
          // user's push token never gets registered.
          return _AccountStatusGate(key: ValueKey(snapshot.data!.uid), uid: snapshot.data!.uid);
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
class _AccountStatusGate extends StatefulWidget {
  const _AccountStatusGate({super.key, required this.uid});

  final String uid;

  @override
  State<_AccountStatusGate> createState() => _AccountStatusGateState();
}

class _AccountStatusGateState extends State<_AccountStatusGate> {
  @override
  void initState() {
    super.initState();
    // Registers this device for match-found pushes. Fire-and-forget on
    // purpose: it's entirely best-effort (see PushNotificationService), and
    // nothing about signing in should wait on a notification permission
    // prompt resolving.
    unawaited(context.read<PushNotificationService>().register());
  }

  @override
  Widget build(BuildContext context) {
    final userRef = FirebaseFirestore.instance.collection('users').doc(widget.uid);
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
        return const MainShell();
      },
    );
  }
}
