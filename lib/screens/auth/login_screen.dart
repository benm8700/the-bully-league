import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import 'package:provider/provider.dart';

import '../../core/services/auth_service.dart';
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
      await authService.signIn(
        email: _emailController.text.trim(),
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
      setState(() => _errorMessage = e.message ?? 'Sign in failed.');
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Log in to The Bully League')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              TextFormField(
                controller: _emailController,
                decoration: const InputDecoration(labelText: 'Email'),
                keyboardType: TextInputType.emailAddress,
                validator: (value) =>
                    (value == null || !value.contains('@')) ? 'Enter a valid email' : null,
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _passwordController,
                decoration: const InputDecoration(labelText: 'Password'),
                obscureText: true,
                validator: (value) =>
                    (value == null || value.isEmpty) ? 'Password is required' : null,
              ),
              const SizedBox(height: 24),
              if (_errorMessage != null) ...[
                Text(_errorMessage!, style: const TextStyle(color: Color(0xFFE05252))),
                const SizedBox(height: 16),
              ],
              FilledButton(
                onPressed: _isSubmitting ? null : _submit,
                child: _isSubmitting
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Log in'),
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
