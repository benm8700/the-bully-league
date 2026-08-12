import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/services/age_verification_service.dart';
import '../../core/services/auth_service.dart';
import 'login_screen.dart';

class SignupScreen extends StatefulWidget {
  const SignupScreen({super.key});

  @override
  State<SignupScreen> createState() => _SignupScreenState();
}

class _SignupScreenState extends State<SignupScreen> {
  final _formKey = GlobalKey<FormState>();
  final _usernameController = TextEditingController();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();

  bool _isSubmitting = false;
  String? _errorMessage;

  @override
  void dispose() {
    _usernameController.dispose();
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
      final ageService = context.read<AgeVerificationService>();
      final isAdult = await ageService.isAdult();
      if (!mounted) return;

      if (!isAdult) {
        await showDialog<void>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Age requirement not met'),
            content: const Text(
              'The Bully League is only available to users 18 and older. '
              'Your account was not created.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('OK'),
              ),
            ],
          ),
        );
        return;
      }

      final authService = context.read<AuthService>();
      final user = await authService.signUp(
        email: _emailController.text.trim(),
        password: _passwordController.text,
      );
      final username = _usernameController.text.trim();
      await user?.updateDisplayName(username);
      await user?.reload();
      if (user != null) {
        // Ranking fields (rating/wins/losses/rankTitle/rankedMatchesPlayed)
        // and accountStatus start at fixed defaults here and are never
        // client-writable again after this create - see firestore.rules and
        // CLAUDE.md's Security & Compliance Baseline. Cloud Functions own
        // rating/wins/losses updates (castVote's finalizeMatch); banning/
        // unbanning (accountStatus) is an admin-only action via the
        // Firebase console, same pattern as profile approval and report
        // review - see CLAUDE.md's Admin/moderation tooling notes.
        await FirebaseFirestore.instance.collection('users').doc(user.uid).set({
          'username': username,
          'rating': 1200,
          'rankTitle': 'Average Joe',
          'rankedMatchesPlayed': 0,
          'wins': 0,
          'losses': 0,
          'accountStatus': 'active',
          'createdAt': FieldValue.serverTimestamp(),
        });
      }
      // AuthGate's StreamBuilder rebuilds to HomeScreen on its own root
      // route as soon as signUp() resolves. That's enough when this
      // screen IS the root (the normal first-launch path), but if it was
      // reached via Navigator.push (the "Sign up" link on LoginScreen),
      // this is a separate route on top that needs an explicit pop to
      // reveal it - see the matching note in LoginScreen. popUntil(isFirst)
      // is a no-op when there's nothing to pop, so it's safe either way.
      if (mounted) Navigator.of(context).popUntil((route) => route.isFirst);
    } on FirebaseAuthException catch (e) {
      setState(() => _errorMessage = e.message ?? 'Sign up failed.');
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Join The Bully League')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              TextFormField(
                controller: _usernameController,
                decoration: const InputDecoration(labelText: 'Username'),
                validator: (value) =>
                    (value == null || value.trim().isEmpty) ? 'Username is required' : null,
              ),
              const SizedBox(height: 16),
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
                    (value == null || value.length < 6) ? 'Min 6 characters' : null,
              ),
              const SizedBox(height: 24),
              if (_errorMessage != null) ...[
                Text(_errorMessage!, style: const TextStyle(color: Colors.red)),
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
                    : const Text('Sign up'),
              ),
              const SizedBox(height: 16),
              TextButton(
                onPressed: _isSubmitting
                    ? null
                    // push, not pushReplacement - see LoginScreen's
                    // matching note. AuthGate must stay mounted underneath
                    // as the root route for its auth-state StreamBuilder to
                    // ever fire HomeScreen once sign-in/sign-up succeeds.
                    : () => Navigator.of(context).push(
                          MaterialPageRoute(builder: (_) => const LoginScreen()),
                        ),
                child: const Text('Already have an account? Log in'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
