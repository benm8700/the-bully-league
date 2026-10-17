import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:provider/provider.dart';

import '../../core/services/age_verification_service.dart';
import '../../core/services/auth_service.dart';
import 'login_screen.dart';

/// Signup has two steps on one screen (not two routes), deliberately: the
/// email/password account is NOT created until the phone code is confirmed,
/// so AuthGate's auth-state StreamBuilder never fires HomeScreen underneath a
/// half-finished signup. If this were two routes, creating the account to
/// link the phone would sign the user in and AuthGate would replace the
/// signup route with Home before the OTP step could run.
enum _SignupStep { details, verify }

class SignupScreen extends StatefulWidget {
  const SignupScreen({super.key});

  @override
  State<SignupScreen> createState() => _SignupScreenState();
}

class _SignupScreenState extends State<SignupScreen> {
  final _detailsKey = GlobalKey<FormState>();
  final _usernameController = TextEditingController();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmController = TextEditingController();
  final _phoneController = TextEditingController();
  final _codeController = TextEditingController();

  bool _obscurePassword = true;

  _SignupStep _step = _SignupStep.details;
  bool _isSubmitting = false; // sending the code / verifying
  bool _finalizing = false; // creating the account after the code is confirmed
  String? _errorMessage;
  String? _phoneE164; // normalized number the code was sent to

  @override
  void dispose() {
    _usernameController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    _confirmController.dispose();
    _phoneController.dispose();
    _codeController.dispose();
    super.dispose();
  }

  /// Turns loose user input into E.164. US-first for the beta/target demo: a
  /// bare 10-digit number becomes +1XXXXXXXXXX, 1-prefixed 11 digits likewise,
  /// and anything already starting with + is trusted as typed. Returns null if
  /// it can't be made into a plausible number (the validator shows the error).
  static String? _normalizePhone(String raw) {
    final trimmed = raw.trim();
    if (trimmed.startsWith('+')) {
      final digits = trimmed.substring(1).replaceAll(RegExp(r'\D'), '');
      return digits.length >= 8 && digits.length <= 15 ? '+$digits' : null;
    }
    final digits = trimmed.replaceAll(RegExp(r'\D'), '');
    if (digits.length == 10) return '+1$digits';
    if (digits.length == 11 && digits.startsWith('1')) return '+$digits';
    return null;
  }

  // --- Step 1: validate details, then send the code ---------------------
  Future<void> _sendCode() async {
    if (!_detailsKey.currentState!.validate()) return;

    setState(() {
      _isSubmitting = true;
      _errorMessage = null;
    });

    try {
      // The name is checked BEFORE anything else, deliberately. A taken or
      // refused name discovered after an account exists leaves someone
      // holding a half-made account with no name, which reads as a broken
      // signup rather than as "pick another".
      final username = _usernameController.text.trim();
      final check = await FirebaseFunctions.instance
          .httpsCallable('checkUsername')
          .call<Map<String, dynamic>>({'username': username});
      if (!mounted) return;
      if (check.data['available'] != true) {
        setState(() {
          _errorMessage =
              check.data['reason'] as String? ?? 'Pick a different username.';
          _isSubmitting = false;
        });
        return;
      }

      final ageService = context.read<AgeVerificationService>();
      final isAdult = await ageService.isAdult();
      if (!mounted) return;
      if (!isAdult) {
        setState(() => _isSubmitting = false);
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

      final phone = _normalizePhone(_phoneController.text);
      if (phone == null) {
        setState(() {
          _errorMessage = 'Enter a valid mobile number.';
          _isSubmitting = false;
        });
        return;
      }
      _phoneE164 = phone;

      final authService = context.read<AuthService>();
      await authService.sendPhoneCode(
        phoneE164: phone,
        onCodeSent: () {
          if (!mounted) return;
          setState(() {
            _step = _SignupStep.verify;
            _isSubmitting = false;
          });
        },
        // Android can read the SMS and resolve the code itself. When it does,
        // finish signup without making the user type anything.
        onAutoResolved: () {
          if (!mounted) return;
          _finalize();
        },
        onError: (message) {
          if (!mounted) return;
          setState(() {
            _errorMessage = message;
            _isSubmitting = false;
          });
        },
      );
    } on FirebaseFunctionsException catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = e.message ?? 'Something went wrong. Try again.';
          _isSubmitting = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _errorMessage = 'Something went wrong. Try again.';
          _isSubmitting = false;
        });
      }
    }
  }

  // --- Step 2: confirm the code, create + link, finish ------------------
  Future<void> _verify() async {
    final code = _codeController.text.trim();
    if (code.length < 6) {
      setState(() => _errorMessage = 'Enter the 6-digit code.');
      return;
    }
    await _finalize(smsCode: code);
  }

  Future<void> _finalize({String? smsCode}) async {
    if (_finalizing) return;
    setState(() {
      _finalizing = true;
      _isSubmitting = true;
      _errorMessage = null;
    });

    final username = _usernameController.text.trim();
    final authService = context.read<AuthService>();
    try {
      // Creates the email/password account (signs in) AND links the verified
      // phone. If the phone is already on another account this throws
      // credential-already-in-use and the half-made account is rolled back
      // inside completePhoneSignup, so no orphan is left.
      final user = await authService.completePhoneSignup(
        email: _emailController.text.trim(),
        password: _passwordController.text,
        smsCode: smsCode,
      );
      await user?.updateDisplayName(username);
      await user?.reload();
      if (user != null) {
        // Ranking fields and accountStatus start at fixed defaults and are
        // never client-writable again (see firestore.rules / CLAUDE.md's
        // Security & Compliance Baseline). The username and the phone number
        // are deliberately NOT written here: firestore.rules refuses both to
        // the client at create as well as update, so the slur filter and the
        // one-account-per-phone claim can't be routed around. setUsername and
        // finalizePhoneSignup (both below) own those two fields.
        await FirebaseFirestore.instance.collection('users').doc(user.uid).set({
          'rating': 1200,
          'rankTitle': 'Average Joe',
          'rankedMatchesPlayed': 0,
          'wins': 0,
          'losses': 0,
          'accountStatus': 'active',
          'isAdmin': false,
          'createdAt': FieldValue.serverTimestamp(),
        });

        try {
          await FirebaseFunctions.instance
              .httpsCallable('setUsername')
              .call<Map<String, dynamic>>({'username': username});
        } catch (_) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text(
                  'Your account is ready, but that username was just taken. '
                  'Pick one from Profile.',
                ),
              ),
            );
          }
        }

        // Refresh the ID token so it carries the just-linked phone_number
        // claim, then record the verified number server-side. finalizePhone
        // Signup reads the number FROM the token (trusted), writes it to the
        // user doc, and attaches any pending phone challenges aimed at it.
        // Best-effort: a failure here must not strand a real, signed-in
        // account on the signup screen - the number can be recorded later.
        try {
          await user.getIdToken(true);
          await FirebaseFunctions.instance
              .httpsCallable('finalizePhoneSignup')
              .call<Map<String, dynamic>>(<String, dynamic>{});
        } catch (_) {
          // non-fatal
        }
      }
      // AuthGate already swapped to HomeScreen when the account was created;
      // pop this route if signup was reached via the Log in <-> Sign up link.
      if (mounted) Navigator.of(context).popUntil((route) => route.isFirst);
    } on FirebaseAuthException catch (e) {
      if (!mounted) return;
      setState(() {
        _finalizing = false;
        _isSubmitting = false;
        switch (e.code) {
          case 'credential-already-in-use':
          case 'account-exists-with-different-credential':
            _errorMessage = 'That phone number is already on another account. '
                'Log in instead.';
            _step = _SignupStep.details;
          case 'email-already-in-use':
            _errorMessage = 'That email is already registered. Log in instead.';
            _step = _SignupStep.details;
          case 'invalid-verification-code':
            _errorMessage = "That code wasn't right. Check it and try again.";
          case 'session-expired':
            _errorMessage = 'That code expired. Tap Resend for a new one.';
          default:
            _errorMessage = e.message ?? 'Sign up failed.';
        }
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _finalizing = false;
          _isSubmitting = false;
          _errorMessage = 'Sign up failed. Try again.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Join The Bully League'),
        leading: _step == _SignupStep.verify
            ? IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: _isSubmitting
                    ? null
                    : () => setState(() {
                          _step = _SignupStep.details;
                          _errorMessage = null;
                          _codeController.clear();
                        }),
              )
            : null,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: _step == _SignupStep.details
            ? _buildDetails(context)
            : _buildVerify(context),
      ),
    );
  }

  Widget _buildDetails(BuildContext context) {
    return Form(
      key: _detailsKey,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          TextFormField(
            controller: _usernameController,
            decoration: const InputDecoration(
              labelText: 'Username',
              helperText: 'Public. Shown on the leaderboard and on clips.',
            ),
            maxLength: 20,
            validator: (value) => (value == null || value.trim().isEmpty)
                ? 'Username is required'
                : null,
          ),
          const SizedBox(height: 16),
          TextFormField(
            controller: _emailController,
            decoration: const InputDecoration(labelText: 'Email'),
            keyboardType: TextInputType.emailAddress,
            validator: (value) => (value == null || !value.contains('@'))
                ? 'Enter a valid email'
                : null,
          ),
          const SizedBox(height: 16),
          TextFormField(
            controller: _passwordController,
            decoration: InputDecoration(
              labelText: 'Password',
              suffixIcon: IconButton(
                icon: Icon(
                  _obscurePassword ? Icons.visibility_off : Icons.visibility,
                ),
                tooltip: _obscurePassword ? 'Show password' : 'Hide password',
                onPressed: () =>
                    setState(() => _obscurePassword = !_obscurePassword),
              ),
            ),
            obscureText: _obscurePassword,
            validator: (value) =>
                (value == null || value.length < 6) ? 'Min 6 characters' : null,
          ),
          const SizedBox(height: 16),
          TextFormField(
            controller: _confirmController,
            decoration: const InputDecoration(labelText: 'Confirm password'),
            // Shares the one show/hide toggle above - typing the same thing
            // twice is the safeguard, so there's no reason to hide one and
            // show the other.
            obscureText: _obscurePassword,
            validator: (value) => (value != _passwordController.text)
                ? "Passwords don't match"
                : null,
          ),
          const SizedBox(height: 16),
          TextFormField(
            controller: _phoneController,
            decoration: const InputDecoration(
              labelText: 'Mobile number',
              helperText: "We'll text a code to confirm it's really you.",
              prefixText: '',
            ),
            keyboardType: TextInputType.phone,
            validator: (value) => (value == null || _normalizePhone(value) == null)
                ? 'Enter a valid mobile number'
                : null,
          ),
          const SizedBox(height: 24),
          if (_errorMessage != null) ...[
            Text(_errorMessage!, style: const TextStyle(color: Color(0xFFE05252))),
            const SizedBox(height: 16),
          ],
          FilledButton(
            onPressed: _isSubmitting ? null : _sendCode,
            child: _isSubmitting
                ? const SizedBox(
                    height: 20,
                    width: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Continue'),
          ),
          const SizedBox(height: 16),
          TextButton(
            onPressed: _isSubmitting
                ? null
                // push, not pushReplacement - AuthGate must stay mounted
                // underneath as the root route for its auth-state
                // StreamBuilder to fire HomeScreen once sign-in succeeds.
                : () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const LoginScreen()),
                    ),
            child: const Text('Already have an account? Log in'),
          ),
        ],
      ),
    );
  }

  Widget _buildVerify(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Enter the code',
          style: Theme.of(context).textTheme.headlineSmall,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 8),
        Text(
          'We texted a 6-digit code to ${_phoneE164 ?? 'your number'}.',
          style: Theme.of(context).textTheme.bodyMedium,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 24),
        TextField(
          controller: _codeController,
          decoration: const InputDecoration(
            labelText: '6-digit code',
            counterText: '',
          ),
          keyboardType: TextInputType.number,
          maxLength: 6,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 24, letterSpacing: 8),
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          onChanged: (v) {
            if (v.length == 6 && !_finalizing) _verify();
          },
        ),
        const SizedBox(height: 16),
        if (_errorMessage != null) ...[
          Text(
            _errorMessage!,
            style: const TextStyle(color: Color(0xFFE05252)),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
        ],
        FilledButton(
          onPressed: _isSubmitting ? null : _verify,
          child: _isSubmitting
              ? const SizedBox(
                  height: 20,
                  width: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Verify & create account'),
        ),
        const SizedBox(height: 8),
        TextButton(
          onPressed: _isSubmitting
              ? null
              : () {
                  _codeController.clear();
                  setState(() => _errorMessage = null);
                  _sendCode();
                },
          child: const Text('Resend code'),
        ),
      ],
    );
  }
}
