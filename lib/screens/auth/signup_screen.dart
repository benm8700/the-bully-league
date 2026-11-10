import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/services/age_verification_service.dart';
import '../../core/services/auth_service.dart';
import 'login_screen.dart';

/// Signup is a short sequence of screens - username, then email + password,
/// then phone, then the texted code - with a "Step N of 4" bar and a back
/// arrow. One question per screen feels lighter than one long form, and it
/// surfaces each error next to the thing that caused it.
///
/// It stays ONE route with internal steps (not four routes), deliberately:
/// the email/password account is NOT created until the phone code is
/// confirmed, and creating it signs the user in. AuthGate keeps this same
/// SignupScreen mounted while signupInProgress is true, so the steps, the
/// typed values and any error all survive that moment. Separate routes would
/// be torn down by AuthGate instead.
enum _SignupStep { age, username, account, phone, verify }

class SignupScreen extends StatefulWidget {
  const SignupScreen({super.key});

  @override
  State<SignupScreen> createState() => _SignupScreenState();
}

class _SignupScreenState extends State<SignupScreen> {
  // One form per input step, so "Next" only validates what is on screen.
  final _usernameKey = GlobalKey<FormState>();
  final _accountKey = GlobalKey<FormState>();
  final _phoneKey = GlobalKey<FormState>();
  // Controllers live for the whole screen, so going Back never loses what
  // was typed.
  final _usernameController = TextEditingController();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _phoneController = TextEditingController();
  final _codeController = TextEditingController();

  bool _obscurePassword = true;

  _SignupStep _step = _SignupStep.age;
  bool _isSubmitting = false; // checking the name / sending or verifying a code
  bool _finalizing = false; // creating the account after the code is confirmed
  String? _errorMessage;
  String? _phoneE164; // normalized number the code was sent to
  // How this person was cleared as 18+: 'platform_signal' when the app store
  // confirmed it, 'self_attested' when the store had no answer and they rely
  // on the "Before you roast" confirmation. Written to the user doc at signup;
  // never a birthdate.
  String _ageAssurance = 'self_attested';

  @override
  void dispose() {
    _usernameController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
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

  void _goTo(_SignupStep step) => setState(() {
    _step = step;
    _errorMessage = null;
  });

  void _back() {
    if (_isSubmitting) return;
    switch (_step) {
      case _SignupStep.account:
        _goTo(_SignupStep.username);
      case _SignupStep.age:
        break;
      case _SignupStep.phone:
        _goTo(_SignupStep.account);
      case _SignupStep.verify:
        _codeController.clear();
        _goTo(_SignupStep.phone);
      case _SignupStep.username:
        _goTo(_SignupStep.age);
    }
  }

  // --- Step 1: username --------------------------------------------------
  // Checked first, deliberately: a taken or refused name is the most common
  // reason signup fails, and finding out before typing anything else saves
  // the frustration (and never leaves a half-made account with no name).
  Future<void> _usernameNext() async {
    if (!_usernameKey.currentState!.validate()) return;
    setState(() {
      _isSubmitting = true;
      _errorMessage = null;
    });
    try {
      final check = await FirebaseFunctions.instance
          .httpsCallable('checkUsername')
          .call<Map<String, dynamic>>({
            'username': _usernameController.text.trim(),
          });
      if (!mounted) return;
      if (check.data['available'] != true) {
        setState(() {
          _errorMessage =
              check.data['reason'] as String? ?? 'Pick a different username.';
          _isSubmitting = false;
        });
        return;
      }
      setState(() => _isSubmitting = false);
      _goTo(_SignupStep.account);
    } catch (_) {
      if (mounted) {
        setState(() {
          _errorMessage = 'Something went wrong. Try again.';
          _isSubmitting = false;
        });
      }
    }
  }

  // --- Step 0: 18+ - our own screen first, THEN the store's native prompt --
  // (beta tester, 2026-11-09: the native age prompt used to pop up in the
  // middle of phone verification and made the whole step feel slow. Now it
  // is the first thing, prefaced by a screen saying why, and accepting here
  // also covers the old separate "Before you roast" page.)
  Future<void> _ageNext() async {
    setState(() {
      _isSubmitting = true;
      _errorMessage = null;
    });
    final ageService = context.read<AgeVerificationService>();
    final age = await ageService.check();
    if (!mounted) return;
    if (age == AgeCheckOutcome.verifyInStore) {
      setState(() => _isSubmitting = false);
      await _showVerifyInPlayStore();
      return;
    }
    _ageAssurance = age == AgeCheckOutcome.adult
        ? 'platform_signal'
        : 'self_attested';
    if (age == AgeCheckOutcome.minor) {
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

    setState(() => _isSubmitting = false);
    _goTo(_SignupStep.username);
  }

  // --- Step 2: email + password (checked on the device) -------------------
  void _accountNext() {
    if (!_accountKey.currentState!.validate()) return;
    _goTo(_SignupStep.phone);
  }

  // --- Step 3: phone - age check, then text the code ----------------------
  Future<void> _phoneNext() async {
    if (!_phoneKey.currentState!.validate()) return;
    setState(() {
      _isSubmitting = true;
      _errorMessage = null;
    });

    await _sendCode();
  }

  /// Texts the code to the number on the phone step. Also used by "Resend
  /// code", which skips the age check (already done for this signup).
  Future<void> _sendCode() async {
    final phone = _normalizePhone(_phoneController.text);
    if (phone == null) {
      setState(() {
        _errorMessage = 'Enter a valid mobile number.';
        _isSubmitting = false;
      });
      return;
    }
    _phoneE164 = phone;
    setState(() {
      _isSubmitting = true;
      _errorMessage = null;
    });
    try {
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
    authService.signupInProgress.value = true;
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
          'ageAssurance': _ageAssurance,
          // Accepted on the 18+ screen that now opens sign-up, so the
          // separate "Before you roast" page is skipped for new accounts.
          'contentPolicyAcceptedAt': FieldValue.serverTimestamp(),
          'createdAt': FieldValue.serverTimestamp(),
        });

        // These two server calls are independent, so run them side by side.
        // Each can hit a cold-start Cloud Function; one after the other they
        // took ~45s in testing, which read as the app having frozen.
        Future<void> claimUsername() async {
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
        }

        // Refresh the ID token so it carries the just-linked phone_number
        // claim, then record the verified number server-side. finalizePhone
        // Signup reads the number FROM the token (trusted), writes it to the
        // user doc, and attaches any pending phone challenges aimed at it.
        // Best-effort: a failure here must not strand a real, signed-in
        // account on the signup screen - the number can be recorded later.
        Future<void> recordPhone() async {
          try {
            await user.getIdToken(true);
            await FirebaseFunctions.instance
                .httpsCallable('finalizePhoneSignup')
                .call<Map<String, dynamic>>(<String, dynamic>{});
          } catch (_) {
            // non-fatal
          }
        }

        await Future.wait([claimUsername(), recordPhone()]);
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
            _errorMessage =
                'That phone number is already on another account. '
                'Log in instead.';
            _step = _SignupStep.phone;
          case 'email-already-in-use':
            _errorMessage = 'That email is already registered. Log in instead.';
            _step = _SignupStep.account;
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
    } finally {
      // Lets AuthGate move on: to Home if the account finished, or stay on
      // this screen (now showing the error) if it was rolled back.
      authService.signupInProgress.value = false;
    }
  }

  /// Play requires this person to verify their age in the Play Store before
  /// it will share it. There's no in-app way to do that, so explain and send
  /// them to the store; they tap Continue again when they're back.
  Future<void> _showVerifyInPlayStore() {
    return showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Verify your age in Google Play'),
        content: const Text(
          'Google Play needs to confirm your age before you can join. Open '
          'the Play Store, follow its age check, then come back and tap '
          'Continue again.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Not now'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.of(context).pop();
              launchUrl(
                Uri.parse('market://details?id=com.bullyleague.app'),
                mode: LaunchMode.externalApplication,
              ).catchError(
                (_) => launchUrl(
                  Uri.parse('https://play.google.com/store'),
                  mode: LaunchMode.externalApplication,
                ),
              );
            },
            child: const Text('Open Play Store'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final stepNumber = _step.index; // the 18+ screen is not a numbered step
    return PopScope(
      // The system back gesture steps back through signup instead of leaving
      // it; only on the first step does it leave (or pop back to Log in).
      canPop: _step == _SignupStep.age && !_finalizing,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && !_finalizing) _back();
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Join The Bully League'),
          leading: _step != _SignupStep.age && !_finalizing
              ? IconButton(
                  icon: const Icon(Icons.arrow_back),
                  tooltip: 'Back',
                  onPressed: _isSubmitting ? null : _back,
                )
              : null,
        ),
        body: _finalizing
            ? _buildFinishing(context)
            : SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (_step != _SignupStep.age) ...[
                      _progress(context, stepNumber),
                      const SizedBox(height: 28),
                    ],
                    switch (_step) {
                      _SignupStep.age => _buildAge(context),
                      _SignupStep.username => _buildUsername(context),
                      _SignupStep.account => _buildAccount(context),
                      _SignupStep.phone => _buildPhone(context),
                      _SignupStep.verify => _buildVerify(context),
                    },
                  ],
                ),
              ),
      ),
    );
  }

  Widget _progress(BuildContext context, int stepNumber) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Step $stepNumber of 4',
          style: Theme.of(
            context,
          ).textTheme.labelMedium?.copyWith(color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(999),
          child: LinearProgressIndicator(
            value: stepNumber / 4,
            minHeight: 6,
            backgroundColor: scheme.surfaceContainerHighest,
          ),
        ),
      ],
    );
  }

  Widget _heading(BuildContext context, String title, [String? subtitle]) {
    final text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: text.headlineSmall),
        if (subtitle != null) ...[
          const SizedBox(height: 6),
          Text(
            subtitle,
            style: text.bodyMedium?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
        const SizedBox(height: 20),
      ],
    );
  }

  Widget _error() {
    if (_errorMessage == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Text(
        _errorMessage!,
        style: const TextStyle(color: Color(0xFFE05252)),
      ),
    );
  }

  Widget _nextButton(VoidCallback onPressed, {String label = 'Next'}) {
    return FilledButton(
      onPressed: _isSubmitting ? null : onPressed,
      child: _isSubmitting
          ? const SizedBox(
              height: 20,
              width: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Text(label),
    );
  }

  /// Shown once the code is accepted, while the account is created and the
  /// server sets the username and records the verified phone. That can take
  /// a while (the backend may be starting up), and before this the screen
  /// just sat there looking reset, so people assumed it had failed.
  Widget _buildFinishing(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 24),
            Text(
              'Setting up your account...',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
            ),
            SizedBox(height: 8),
            Text('Just a few seconds.', textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }

  Widget _buildAge(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    Widget line(String emoji, String body) => Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(emoji, style: const TextStyle(fontSize: 20)),
          const SizedBox(width: 12),
          Expanded(child: Text(body, style: text.bodyLarge)),
        ],
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 8),
        Text('You must be 18+', style: text.headlineMedium),
        const SizedBox(height: 8),
        Text(
          'The Bully League is live roast battles with strangers.',
          style: text.bodyLarge?.copyWith(color: muted),
        ),
        const SizedBox(height: 24),
        line(
          '🎤',
          'Expect strong language and offensive comedy - that is the '
              'point.',
        ),
        line(
          '🚫',
          'No hate speech, nudity, threats or anything involving '
              'kids. Those get you banned.',
        ),
        line('📱', 'Next, your phone may ask to confirm your age.'),
        const SizedBox(height: 16),
        _error(),
        _nextButton(_ageNext, label: "I'm 18 or older"),
        const SizedBox(height: 8),
        TextButton(
          onPressed: _isSubmitting
              ? null
              : () => Navigator.of(context).maybePop(),
          child: const Text('Not for me'),
        ),
      ],
    );
  }

  Widget _buildUsername(BuildContext context) {
    return Form(
      key: _usernameKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _heading(
            context,
            'Pick your username',
            'Public. Shown on the leaderboard and on clips.',
          ),
          TextFormField(
            controller: _usernameController,
            autofocus: true,
            decoration: const InputDecoration(labelText: 'Username'),
            maxLength: 20,
            textInputAction: TextInputAction.next,
            onFieldSubmitted: (_) => _usernameNext(),
            // A "That username is taken." about the PREVIOUS name must not
            // sit there while they type a new one.
            onChanged: (_) {
              if (_errorMessage != null) setState(() => _errorMessage = null);
            },
            validator: (value) => (value == null || value.trim().isEmpty)
                ? 'Username is required'
                : null,
          ),
          const SizedBox(height: 16),
          _error(),
          _nextButton(_usernameNext),
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

  Widget _buildAccount(BuildContext context) {
    return Form(
      key: _accountKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _heading(
            context,
            'Email and password',
            "You'll use these to log in.",
          ),
          TextFormField(
            controller: _emailController,
            autofocus: true,
            decoration: const InputDecoration(labelText: 'Email'),
            keyboardType: TextInputType.emailAddress,
            textInputAction: TextInputAction.next,
            autofillHints: const [AutofillHints.email],
            validator: (value) => (value == null || !value.contains('@'))
                ? 'Enter a valid email'
                : null,
          ),
          const SizedBox(height: 16),
          // No "confirm password" field: the eye icon lets people check what
          // they typed, which is how most modern apps handle it.
          TextFormField(
            controller: _passwordController,
            decoration: InputDecoration(
              labelText: 'Password',
              helperText: 'At least 6 characters',
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
            textInputAction: TextInputAction.done,
            autofillHints: const [AutofillHints.newPassword],
            onFieldSubmitted: (_) => _accountNext(),
            validator: (value) =>
                (value == null || value.length < 6) ? 'Min 6 characters' : null,
          ),
          const SizedBox(height: 24),
          _error(),
          _nextButton(_accountNext),
        ],
      ),
    );
  }

  Widget _buildPhone(BuildContext context) {
    return Form(
      key: _phoneKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _heading(
            context,
            "What's your phone number?",
            "We'll text you a code to confirm it's you. One account per number.",
          ),
          TextFormField(
            controller: _phoneController,
            autofocus: true,
            decoration: const InputDecoration(labelText: 'Mobile number'),
            keyboardType: TextInputType.phone,
            textInputAction: TextInputAction.done,
            autofillHints: const [AutofillHints.telephoneNumber],
            onFieldSubmitted: (_) => _phoneNext(),
            validator: (value) =>
                (value == null || _normalizePhone(value) == null)
                ? 'Enter a valid mobile number'
                : null,
          ),
          const SizedBox(height: 24),
          _error(),
          _nextButton(_phoneNext, label: 'Send code'),
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
                  _sendCode();
                },
          child: const Text('Resend code'),
        ),
      ],
    );
  }
}
