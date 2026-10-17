import 'package:firebase_auth/firebase_auth.dart';

/// Wraps Firebase Auth so screens never call the Firebase SDK directly —
/// consistent with the "risky/replaceable dependency behind an interface"
/// rule in CLAUDE.md's Project Folder Structure section.
class AuthService {
  AuthService(this._auth);

  final FirebaseAuth _auth;

  User? get currentUser => _auth.currentUser;

  /// Uses userChanges() rather than authStateChanges() so the UI also
  /// rebuilds after profile updates (e.g. setting displayName right after
  /// sign-up), not just on sign-in/sign-out.
  Stream<User?> authStateChanges() => _auth.userChanges();

  Future<User?> signUp({required String email, required String password}) async {
    final credential = await _auth.createUserWithEmailAndPassword(
      email: email,
      password: password,
    );
    return credential.user;
  }

  // --- Phone verification (signup) --------------------------------------
  //
  // The whole Firebase phone flow lives here so screens never touch the SDK
  // (the "risky dependency behind an interface" rule). The screen drives it
  // with Strings and callbacks only: send a code, then complete signup with
  // the typed code. On Android the code often auto-resolves (the OS reads the
  // SMS), which [sendPhoneCode] surfaces via onAutoResolved so the screen can
  // finish without the user typing anything.

  String? _phoneVerificationId;
  PhoneAuthCredential? _autoPhoneCred;

  /// Sends a verification SMS to [phoneE164] (must be full E.164, e.g.
  /// +15551234567). Does NOT create an account - that happens in
  /// [completePhoneSignup] once the code is confirmed.
  Future<void> sendPhoneCode({
    required String phoneE164,
    required void Function() onCodeSent,
    required void Function() onAutoResolved,
    required void Function(String message) onError,
  }) async {
    _phoneVerificationId = null;
    _autoPhoneCred = null;
    await _auth.verifyPhoneNumber(
      phoneNumber: phoneE164,
      verificationCompleted: (cred) {
        // Android auto-retrieval: the credential is ready without a typed code.
        _autoPhoneCred = cred;
        onAutoResolved();
      },
      verificationFailed: (e) =>
          onError(e.message ?? 'Could not send a code to that number.'),
      codeSent: (verificationId, _) {
        _phoneVerificationId = verificationId;
        onCodeSent();
      },
      codeAutoRetrievalTimeout: (verificationId) {
        _phoneVerificationId = verificationId;
      },
    );
  }

  /// Finishes signup: creates the email/password account, then LINKS the
  /// verified phone to it (so one account holds both and the phone is a
  /// trusted claim on the user's token). [smsCode] is the typed code; pass
  /// null to use an auto-resolved credential.
  ///
  /// On a phone already tied to another account, deletes the just-created
  /// account and rethrows `credential-already-in-use` so the screen can tell
  /// the user to log in instead - no orphaned account is left behind.
  Future<User?> completePhoneSignup({
    required String email,
    required String password,
    String? smsCode,
  }) async {
    final phoneCred = _autoPhoneCred ??
        (_phoneVerificationId != null && smsCode != null
            ? PhoneAuthProvider.credential(
                verificationId: _phoneVerificationId!, smsCode: smsCode)
            : null);
    if (phoneCred == null) {
      throw FirebaseAuthException(
          code: 'missing-code', message: 'Enter the code we texted you.');
    }
    final result = await _auth.createUserWithEmailAndPassword(
      email: email,
      password: password,
    );
    final user = result.user;
    try {
      await user?.linkWithCredential(phoneCred);
    } catch (e) {
      // The account exists but the phone could not be linked (most often it
      // is already on another account). Roll the half-made account back.
      await user?.delete().catchError((_) {});
      rethrow;
    }
    _phoneVerificationId = null;
    _autoPhoneCred = null;
    return user;
  }

  Future<User?> signIn({required String email, required String password}) async {
    final credential = await _auth.signInWithEmailAndPassword(
      email: email,
      password: password,
    );
    return credential.user;
  }

  Future<void> signOut() => _auth.signOut();
}
