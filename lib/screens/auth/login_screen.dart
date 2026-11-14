import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import 'package:provider/provider.dart';

import '../../core/services/auth_service.dart';
import '../../widgets/neon_action_button.dart';
import 'signup_screen.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();

  bool _isSubmitting = false;
  String? _errorMessage;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _isSubmitting = true;
      _errorMessage = null;
    });

    try {
      final authService = context.read<AuthService>();
      var email = _emailController.text.trim();
      // No "@" = a phone number. The server checks the password against the
      // account on that number and only then returns its email, so this
      // can't be used to look up someone's email from their number.
      if (!email.contains('@')) {
        try {
          final r = await FirebaseFunctions.instance
              .httpsCallable('resolvePhoneLogin')
              .call<Map<String, dynamic>>({
                'phone': email,
                'password': _passwordController.text,
              });
          email = r.data['email'] as String;
        } on FirebaseFunctionsException catch (e) {
          setState(
            () => _errorMessage = e.message ?? 'Could not log in. Try again.',
          );
          return;
        }
      }
      if (!mounted) return;
      await authService.signIn(
        email: email,
        password: _passwordController.text,
      );
      if (!mounted) return;
      // AuthGate's StreamBuilder rebuilds to HomeScreen as soon as
      // signIn() resolves, but that rebuild happens on the ROOT route -
      // this screen was reached via Navigator.push (from the "Log in"
      // link on SignupScreen), so it's a separate route sitting on top
      // and won't disappear on its own. Without this pop, the app would
      // stay stuck showing this screen forever despite being signed in
      // (confirmed live: signInWithEmailAndPassword succeeded and
      // persisted a session, but the screen never advanced until a full
      // app relaunch picked the session back up through AuthGate fresh).
      Navigator.of(context).popUntil((route) => route.isFirst);
    } on FirebaseAuthException catch (e) {
      setState(() => _errorMessage = _friendlyError(e));
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  /// Firebase's own messages are developer-facing ("The supplied auth
  /// credential is incorrect, malformed or has expired."). Wrong email and
  /// wrong password deliberately read the same - saying which one was wrong
  /// tells an attacker which emails have accounts.
  static String _friendlyError(FirebaseAuthException e) {
    switch (e.code) {
      case 'invalid-credential':
      case 'wrong-password':
      case 'user-not-found':
      case 'invalid-email':
        return 'Wrong email, phone number or password.';
      case 'too-many-requests':
        return 'Too many attempts. Wait a few minutes and try again, '
            'or reset your password.';
      case 'user-disabled':
        return 'This account has been disabled.';
      case 'network-request-failed':
        return 'No connection. Check your internet and try again.';
      default:
        return 'Could not log in. Try again.';
    }
  }

  /// "Forgot password?" - emails a reset link to whatever is in the Email
  /// field. Before this existed, a forgotten password meant the account was
  /// gone for good (there was no recovery path anywhere in the app).
  Future<void> _forgotPassword() async {
    final email = _emailController.text.trim();
    if (!email.contains('@')) {
      setState(
        () => _errorMessage =
            'Type your email (not your phone number) above first, then tap '
            '"Forgot password?".',
      );
      return;
    }
    setState(() {
      _isSubmitting = true;
      _errorMessage = null;
    });
    try {
      await context.read<AuthService>().sendPasswordReset(email);
    } on FirebaseAuthException catch (e) {
      // Only surface problems the user can act on; anything else gets the
      // same neutral confirmation, so this can't be used to probe which
      // emails have accounts.
      if (e.code == 'invalid-email' || e.code == 'network-request-failed') {
        if (mounted) setState(() => _errorMessage = _friendlyError(e));
        if (mounted) setState(() => _isSubmitting = false);
        return;
      }
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'If $email has an account, a reset link is on its way. '
          'Check your inbox (and spam).',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Log in')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              TextFormField(
                controller: _emailController,
                decoration: const InputDecoration(
                  labelText: 'Email or phone number',
                ),
                keyboardType: TextInputType.emailAddress,
                autocorrect: false,
                validator: (value) {
                  final v = value?.trim() ?? '';
                  if (v.contains('@')) return null;
                  final digits = v.replaceAll(RegExp(r'[^0-9]'), '');
                  return digits.length >= 10
                      ? null
                      : 'Enter your email or phone number';
                },
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _passwordController,
                decoration: const InputDecoration(labelText: 'Password'),
                obscureText: true,
                validator: (value) => (value == null || value.isEmpty)
                    ? 'Password is required'
                    : null,
              ),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: _isSubmitting ? null : _forgotPassword,
                  child: const Text('Forgot password?'),
                ),
              ),
              const SizedBox(height: 8),
              if (_errorMessage != null) ...[
                Text(
                  _errorMessage!,
                  style: const TextStyle(color: Color(0xFFE05252)),
                ),
                const SizedBox(height: 16),
              ],
              NeonActionButton(
                label: 'Log in',
                compact: true,
                busy: _isSubmitting,
                onPressed: _isSubmitting ? null : _submit,
              ),
              const SizedBox(height: 16),
              TextButton(
                onPressed: _isSubmitting
                    ? null
                    // push, not pushReplacement: AuthGate (the root route)
                    // must stay alive underneath so its auth-state
                    // StreamBuilder is still there to react once sign-in/
                    // sign-up succeeds - see the popUntil note above for
                    // what breaks otherwise (confirmed live: with
                    // pushReplacement this becomes a NEW root route with
                    // no AuthGate left, so nothing ever navigates to
                    // HomeScreen no matter what auth state does).
                    : () => Navigator.of(context).push(
                        MaterialPageRoute(builder: (_) => const SignupScreen()),
                      ),
                child: const Text("Don't have an account? Sign up"),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
