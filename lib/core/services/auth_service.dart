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

  Future<User?> signIn({required String email, required String password}) async {
    final credential = await _auth.signInWithEmailAndPassword(
      email: email,
      password: password,
    );
    return credential.user;
  }

  Future<void> signOut() => _auth.signOut();
}
