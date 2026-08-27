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
import 'theme/app_theme.dart';
import 'screens/auth/signup_screen.dart';
import 'screens/home/main_shell.dart';
import 'screens/moderation/banned_screen.dart';

/// A theme id shared with the in-app picker, so cycling it rebuilds the
/// whole app in the next direction. A plain global ValueNotifier rather
/// than a provider because it is a dev-only preview control with a single
/// consumer - the app root.
final ValueNotifier<String> kActiveTheme = ValueNotifier(kThemeIds.first);

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
      child: ValueListenableBuilder<String>(
        valueListenable: kActiveTheme,
        builder: (context, themeId, _) {
          final theme = appTheme(themeId);
          return MaterialApp(
            title: 'The Bully League',
            // One theme, whichever direction the picker has selected.
            // Each direction sets its own brightness, so themeMode is
            // forced to match rather than following the device.
            themeMode: theme.brightness == Brightness.dark
                ? ThemeMode.dark
                : ThemeMode.light,
            theme: theme,
            darkTheme: theme,
            home: const AuthGate(),
          );
        },
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
  // Applies the account's saved skin exactly ONCE per account load, so a
  // later in-session change (equipping in the Appearance screen, or the dev
  // preview toggle) is never clobbered by a subsequent user-doc snapshot.
  // Reset naturally on account switch, since this gate is keyed by uid.
  bool _appliedSkin = false;

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
        // Restore the persisted skin (CLAUDE.md's earned-skins system) from
        // the user document, which this gate already streams. Done in a
        // post-frame callback because kActiveTheme is listened to by an
        // ANCESTOR (the MaterialApp above): mutating it during this
        // descendant's build would try to mark that ancestor dirty
        // mid-build, which Flutter forbids.
        final data = snapshot.data?.data();
        if (!_appliedSkin && data != null) {
          final skin = data['equippedSkin'] as String?;
          _appliedSkin = true;
          if (skin != null && skin.isNotEmpty && skin != kActiveTheme.value) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              kActiveTheme.value = skin;
            });
          }
        }
        final accountStatus = data?['accountStatus'] as String?;
        if (accountStatus == 'banned') {
          return const BannedScreen();
        }
        return const MainShell();
      },
    );
  }
}
