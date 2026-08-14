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
  try {
    await FirebaseAppCheck.instance.activate(
      // Play Integrity verifies the app was installed from Google Play, so
      // a debug or sideloaded build cannot pass it - by design. Debug
      // builds therefore use the debug provider, which prints a token to
      // the console to be registered once per device. Without this split,
      // every emulator would fail attestation the moment enforcement went
      // on, and it would look like a backend fault rather than the
      // expected behaviour of a build that did not come from the store.
      providerAndroid: kDebugMode
          ? const AndroidDebugProvider()
          : const AndroidPlayIntegrityProvider(),
      providerApple: kDebugMode
          ? const AppleDebugProvider()
          : const AppleAppAttestProvider(),
    );
  } catch (e) {
    debugPrint('App Check activation failed (unenforced, continuing): $e');
  }
}
