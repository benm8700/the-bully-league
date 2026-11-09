import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'core/route_observer.dart';
import 'core/services/age_verification_service.dart';
import 'core/services/app_presence_service.dart';
import 'core/services/auth_service.dart';
import 'core/services/cloud_vision_moderation_service.dart';
import 'core/services/push_notification_service.dart';
import 'core/services/push_tap_router.dart';
import 'core/services/visual_moderation_service.dart';
import 'theme/app_theme.dart';
import 'widgets/window_skin_controller.dart';
import 'screens/auth/signup_screen.dart';
import 'screens/battles/get_clip_sheet.dart';
import 'screens/home/main_shell.dart';
import 'screens/moderation/banned_screen.dart';
import 'screens/onboarding/content_policy_screen.dart';

/// The everyday base skin everyone gets. Comedy Night is the brand default;
/// Card/Aurora and the other explorations are kept in app_theme.dart for
/// future use, and Neon stays the earned GOAT prestige unlock.
const String kBaseSkin = 'comedyNight';

/// Nightlife: navy-black / violet / champagne-gold. Once the AUTOMATIC skin
/// the whole app wore during Sixes and Sevens ("the lights change at 6") -
/// but that app-wide palette swap was DROPPED (2026-08-31, the developer's
/// call): swapping the entire look for an hour risked reading as a different
/// app to anyone opening it fresh during the window, and undercut the Comedy
/// Night brand identity. Nightlife is preserved as an unlockable PRESTIGE
/// SKIN (the developer's favourite), alongside Neon. The window now gets an
/// unmistakable LIVE CUE instead (see WindowLiveBar) rather than a full
/// repaint. The kept constant name is historical.
const String kWindowSkin = 'nightlife';

/// Skins a client may actually equip. Anything else on a user document (a
/// legacy 'card', a dev preview) falls back to the base rather than
/// rendering a retired skin. Nightlife and Neon are prestige unlocks (see
/// AppearanceScreen); the future plan is that all skins become paid unlocks.
const Set<String> kEquippableSkins = {kBaseSkin, 'neon', kWindowSkin};

/// The user's chosen skin (persisted as users/{uid}.equippedSkin). This is
/// what the app wears - there is no longer any window override on top of it.
final ValueNotifier<String> kEquippedSkin = ValueNotifier(kBaseSkin);

/// Whether Sixes and Sevens is live right now, maintained by
/// [WindowSkinController]. Drives the LIVE CUE (WindowLiveBar), not the
/// theme - the automatic skin swap was dropped.
final ValueNotifier<bool> kWindowLive = ValueNotifier(false);

/// The current window's display name, maintained by [WindowSkinController]
/// from config/eventWindow so the LIVE CUE names it correctly even though
/// the name is provisional and console-tunable. Defaults to the documented
/// name so the cue reads right before the config resolves.
final ValueNotifier<String> kWindowName = ValueNotifier('Happy Hour');

/// The effective theme the MaterialApp renders: simply the user's equipped
/// skin. Derived from [kEquippedSkin] - never set directly.
final ValueNotifier<String> kActiveTheme = ValueNotifier(kBaseSkin);

bool _themeWired = false;

/// Wires [kActiveTheme] to follow [kEquippedSkin]. Idempotent so it can be
/// called from the app-root build.
void wireActiveTheme() {
  if (_themeWired) return;
  _themeWired = true;
  void recompute() {
    kActiveTheme.value = kEquippedSkin.value;
  }

  kEquippedSkin.addListener(recompute);
  recompute();
}

class BullyLeagueApp extends StatelessWidget {
  const BullyLeagueApp({super.key});

  @override
  Widget build(BuildContext context) {
    wireActiveTheme();
    return MultiProvider(
      providers: [
        Provider<AuthService>(
          create: (_) => AuthService(FirebaseAuth.instance),
        ),
        Provider<AgeVerificationService>(
          create: (_) => PlatformAgeVerificationService(),
        ),
        Provider<VisualModerationService>(
          create: (_) => CloudVisionModerationService(),
        ),
        Provider<PushNotificationService>(
          create: (_) => PushNotificationService(),
        ),
      ],
      child: ValueListenableBuilder<String>(
        valueListenable: kActiveTheme,
        builder: (context, themeId, _) {
          final theme = appTheme(themeId);
          return MaterialApp(
            title: 'The Bully League',
            // Lets the looping video players pause when covered by another
            // screen, not just when the app is backgrounded (route_observer.dart).
            navigatorObservers: [appRouteObserver],
            // Lets a tapped push notification open a screen (PushTapRouter).
            navigatorKey: appNavigatorKey,
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

class AuthGate extends StatefulWidget {
  const AuthGate({super.key});

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  // Created ONCE. authStateChanges() returns a new Stream object on every
  // call, and handing StreamBuilder a different stream makes it drop back to
  // "waiting" (a spinner), which unmounts SignupScreen and throws away its
  // state - including the error message a failed signup just set.
  late final AuthService _authService = context.read<AuthService>();
  late final Stream<User?> _authStream = _authService.authStateChanges();

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: _authStream,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        return ValueListenableBuilder<bool>(
          valueListenable: _authService.signupInProgress,
          builder: (context, signingUp, _) {
            // Mid-signup the account already exists (so the user is "signed
            // in"), but it isn't finished and may still be rolled back. Keep
            // the same SignupScreen mounted so its state and any error
            // survive.
            if (signingUp) return const SignupScreen();
            if (snapshot.hasData) {
              // Keyed by uid so signing in as a different account builds a
              // fresh State - otherwise Flutter reuses the element and the
              // new user's push token never gets registered.
              return _AccountStatusGate(
                key: ValueKey(snapshot.data!.uid),
                uid: snapshot.data!.uid,
              );
            }
            return const SignupScreen();
          },
        );
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

  // Push registration is deferred until the account has accepted the
  // content policy (see build). Registering in initState popped the OS
  // "Allow notifications?" prompt ON TOP of the 18+ acknowledgement, asking
  // a brand-new user for a permission before they had even agreed to use
  // the app (found live, 2026-11-08). Once per account, like _appliedSkin.
  bool _pushRegistered = false;

  void _registerPushOnce() {
    if (_pushRegistered) return;
    _pushRegistered = true;
    // Fire-and-forget on purpose: it's entirely best-effort (see
    // PushNotificationService), and nothing should wait on a notification
    // permission prompt resolving.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(context.read<PushNotificationService>().register());
      // Only now is MainShell up, so a tapped notification has a home to
      // open its screen on top of (and to come back to).
      unawaited(PushTapRouter.instance.start());
    });
  }

  // The clip-ready pop-up (server sets users/{uid}.clipReadyPopup when a
  // claimed clip finishes captioning). Shown once per clip, then cleared.
  // The push covers people outside the app; this covers people IN it, who
  // would otherwise never notice a notification banner mid-scroll
  // (developer's call, 2026-11-08).
  String? _clipPopupShownFor;

  void _maybeShowClipReady(Map<String, dynamic> data) {
    final popup = data['clipReadyPopup'] as Map<String, dynamic>?;
    final matchId = popup?['matchId'] as String?;
    if (matchId == null || matchId == _clipPopupShownFor) return;
    _clipPopupShownFor = matchId;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final ctx = appNavigatorKey.currentContext;
      if (!mounted || ctx == null) return;
      // Clear first: dismissing, watching, or the app dying mid-dialog
      // must never make it pop up again.
      unawaited(FirebaseFirestore.instance
          .collection('users')
          .doc(widget.uid)
          .update({'clipReadyPopup': FieldValue.delete()})
          .catchError((_) {}));
      final watch = await showDialog<bool>(
        context: ctx,
        builder: (dCtx) => AlertDialog(
          icon: const Icon(Icons.movie_creation_outlined, size: 36),
          title: const Text('Your clip is ready!'),
          content: const Text(
            'Your battle is cut, captioned and ready to watch, save to your '
            'phone, or post.',
            textAlign: TextAlign.center,
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dCtx).pop(false),
              child: const Text('Later'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dCtx).pop(true),
              child: const Text('Watch it'),
            ),
          ],
        ),
      );
      final again = appNavigatorKey.currentContext;
      if (watch == true && again != null && again.mounted) {
        unawaited(GetClipSheet.show(again, matchId));
      }
    });
  }

  @override
  void initState() {
    super.initState();
    // "App open" presence for the admin dashboard - foreground-only heartbeat,
    // no background work, negligible cost. See AppPresenceService.
    AppPresenceService.instance.start(widget.uid);
  }

  @override
  void dispose() {
    AppPresenceService.instance.stop();
    PushTapRouter.instance.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final userRef = FirebaseFirestore.instance
        .collection('users')
        .doc(widget.uid);
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: userRef.snapshots(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        // Restore the persisted skin (CLAUDE.md's earned-skins system) from
        // the user document, which this gate already streams. Done in a
        // post-frame callback because kActiveTheme is listened to by an
        // ANCESTOR (the MaterialApp above): mutating it during this
        // descendant's build would try to mark that ancestor dirty
        // mid-build, which Flutter forbids.
        final data = snapshot.data?.data();
        if (!_appliedSkin && data != null) {
          _appliedSkin = true;
          // Restore the persisted skin, falling back to the base for a
          // retired skin (a legacy 'card') or nothing at all - so an old
          // account never renders a skin no longer offered. The window
          // override, if live, wins over this via kActiveTheme.
          final skin = data['equippedSkin'] as String?;
          final effective = (skin != null && kEquippableSkins.contains(skin))
              ? skin
              : kBaseSkin;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            kEquippedSkin.value = effective;
          });
        }
        final accountStatus = data?['accountStatus'] as String?;
        // WindowSkinController keeps kWindowLive current so the whole app -
        // battlers AND spectators - shifts to the event skin during Sixes
        // and Sevens. Mounted here so it runs for every signed-in surface.
        if (accountStatus == 'banned') {
          return const WindowSkinController(child: BannedScreen());
        }
        // One-time content-policy + age acknowledgement. Gated on the
        // `contentPolicyAcceptedAt` flag so it shows exactly once - and, being
        // a flag rather than a signup step, it also catches every existing
        // account on their next open. Only when the doc actually exists: a
        // null doc means mid-signup, so fall through and it appears once the
        // doc lands. Accept writes the flag and this stream re-renders into
        // MainShell (Battle tab); Decline just holds the user on that screen.
        if (data != null && data['contentPolicyAcceptedAt'] == null) {
          return WindowSkinController(
            child: ContentPolicyScreen(uid: widget.uid),
          );
        }
        if (data != null) {
          _registerPushOnce();
          _maybeShowClipReady(data);
        }
        return const WindowSkinController(child: MainShell());
      },
    );
  }
}
