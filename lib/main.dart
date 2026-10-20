import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'app.dart';
import 'firebase_options.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  await _activateAppCheck();
  runApp(const BullyLeagueApp());
}

/// Attests that requests come from the genuine app on a real device.
///
/// WHY THIS EXISTS. Voting is the scarce resource this app runs on, and a
/// CAPTCHA between every ballot would make judging a chore - which is why
/// verification is currently sold in bounded sessions instead (see
/// functions/voteSession.js). Play Integrity replaces that trade entirely:
/// it is invisible to the user and considerably harder to farm than CAPTCHA
/// solves, which go for about a dollar per thousand.
///
/// It is NOT the main defence against vote manipulation and should not be
/// mistaken for one. Swinging a match needs many distinct ACCOUNTS, because
/// one ballot per account per match is already enforced - account scarcity
/// is phone verification's job. App Check kills scripted clients, not
/// someone with twenty phones.
///
/// NOTHING IS ENFORCED YET, deliberately. Enforcement turned on before real
/// clients are sending tokens breaks every installed build instantly, so
/// this runs in Firebase's monitoring period first: tokens flow, traffic is
/// observed, and enforcement is switched on only once the metrics show
/// genuine requests arriving.
///
/// Failure is swallowed on purpose. While unenforced, a device that cannot
/// attest still works normally, and letting attestation failure stop the
/// app from starting would be a far worse bug than the one it prevents.
Future<void> _activateAppCheck() async {
  // ANDROID APP CHECK IS DISABLED FOR NOW, and this is deliberate. App Check is
  // unenforced everywhere (no callable requires a token), and a sideloaded
  // Android build can NEVER pass Play Integrity - it only fails, and repeated
  // attempts across reinstalls hit a "Too many attempts" throttle that then
  // HANGS every callable, because the Firebase SDK blocks a call waiting for a
  // token that never comes (seen as a frozen Home and a match that won't
  // start). Since it buys nothing while unenforced and breaks the test devices,
  // skip it on Android. The real iOS beta keeps App Attest below. Re-enable
  // Android (Play Integrity) when the app actually ships from Google Play and
  // App Check is about to be enforced.
  if (defaultTargetPlatform == TargetPlatform.android) return;
  try {
    await FirebaseAppCheck.instance.activate(
      providerApple: kDebugMode
          ? const AppleDebugProvider()
          : const AppleAppAttestProvider(),
    );
  } catch (e) {
    debugPrint('App Check activation failed (unenforced, continuing): $e');
  }
}
