import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../../core/battle_card.dart';
import '../../core/countries.dart';
import '../../theme/app_theme.dart';
import '../../widgets/country_picker.dart';
import '../../widgets/neon_action_button.dart';
import '../profile/intro_video_card.dart';
import '../profile/selfie_card.dart';

/// RANKED SETUP (2026-11-14, developer's design): the first time a player taps
/// Ranked, one question per screen instead of a long profile form - name,
/// where you're from, selfie, intro video, about me - ending on "Setup
/// complete". Username and password stay at sign-up (friend battles need an
/// account). Only the steps a player is missing are shown
/// ([setupStepsNeeded]). Pops `true` once finished so the caller can carry
/// straight on into the ranked flow.
class RankedSetupScreen extends StatefulWidget {
  const RankedSetupScreen({super.key, required this.steps});

  final List<SetupStep> steps;

  /// Opens the flow if anything is missing. Returns true when the player is
  /// set up (already, or just now), false if they backed out.
  static Future<bool> runIfNeeded(BuildContext context) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return true;
    List<SetupStep> steps;
    try {
      final snap = await FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .get();
      steps = setupStepsNeeded(snap.data());
    } catch (_) {
      return true; // fail open - the server still gates intro + selfie
    }
    if (steps.isEmpty) return true;
    if (!context.mounted) return false;
    final ok = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => RankedSetupScreen(steps: steps)),
    );
    return ok == true;
  }

  @override
  State<RankedSetupScreen> createState() => _RankedSetupScreenState();
}

class _RankedSetupScreenState extends State<RankedSetupScreen> {
  int _i = 0; // index into widget.steps; == length means "done"
  bool _busy = false;
  String? _error;

  final _name = TextEditingController();
  final _city = TextEditingController();
  final _about = TextEditingController();
  String? _country = deviceCountryCode();

  bool _hasSelfie = false;
  bool _hasIntro = false;
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _sub;

  DocumentReference<Map<String, dynamic>> get _userRef => FirebaseFirestore
      .instance
      .collection('users')
      .doc(FirebaseAuth.instance.currentUser!.uid);

  @override
  void initState() {
    super.initState();
    _sub = _userRef.snapshots().listen((snap) {
      final p = (snap.data()?['profile'] as Map?) ?? const {};
      String s(Object? v) => (v is String) ? v.trim() : '';
      if (!mounted) return;
      setState(() {
        _hasSelfie = s(p['facePhotoUrl']).isNotEmpty;
        _hasIntro = s(p['introVideoUrl']).isNotEmpty;
        // Pre-fill anything already there (e.g. typed on an older build).
        if (_name.text.isEmpty) _name.text = s(p['name']);
        if (_city.text.isEmpty) _city.text = s(p['hometown']);
        if (s(p['country']).isNotEmpty) _country = s(p['country']);
        if (_about.text.isEmpty) _about.text = s(p['ammoText']);
      });
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _name.dispose();
    _city.dispose();
    _about.dispose();
    super.dispose();
  }

  bool get _done => _i >= widget.steps.length;
  SetupStep? get _step => _done ? null : widget.steps[_i];

  bool get _canContinue => switch (_step) {
    SetupStep.name => _name.text.trim().isNotEmpty,
    SetupStep.location => _country != null,
    SetupStep.selfie => _hasSelfie,
    SetupStep.intro => _hasIntro,
    SetupStep.about || null => true,
  };

  Future<void> _next({bool skip = false}) async {
    FocusManager.instance.primaryFocus?.unfocus();
    final step = _step;
    final fields = <String, String>{
      if (step == SetupStep.name) 'name': _name.text.trim(),
      if (step == SetupStep.location) ...{
        'hometown': _city.text.trim(),
        'country': _country ?? '',
      },
      if (step == SetupStep.about && !skip) 'ammoText': _about.text.trim(),
    };
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (fields.isNotEmpty) {
        final blocked = await blockedProfileFields(fields);
        if (blocked.isNotEmpty) {
          setState(() => _error = kProfileTextRefused);
          return;
        }
        await saveProfileFields(_userRef, fields);
      }
      if (_i == widget.steps.length - 1) {
        await _userRef.update({
          'profile.rankedSetupDoneAt': FieldValue.serverTimestamp(),
        });
      }
      if (mounted) setState(() => _i++);
    } catch (_) {
      if (mounted) {
        setState(() => _error = "Couldn't save that. Check your connection.");
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Back steps back through the flow (2026-11-14, developer's report: it
    // used to drop you on Home from any step). Only step 1 leaves; on the
    // final screen it leaves as "set up" since everything is saved.
    return PopScope(
      canPop: _i == 0 && !_done,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop || _busy) return;
        if (_done) {
          Navigator.of(context).pop(true);
        } else if (_i > 0) {
          setState(() {
            _i--;
            _error = null;
          });
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: _done
              ? null
              : Text('Step ${_i + 1} of ${widget.steps.length}'),
          automaticallyImplyLeading: !_done,
        ),
        body: SafeArea(
          child: _done ? _buildDone(context) : _buildStep(context, _step!),
        ),
      ),
    );
  }

  Widget _buildStep(BuildContext context, SetupStep step) {
    final (title, sub) = switch (step) {
      SetupStep.name => (
        'What should opponents call you?',
        'Your first name. It shows on your battle card during a battle.',
      ),
      SetupStep.location => (
        'Where are you from?',
        'Only your opponent sees this. City is optional.',
      ),
      SetupStep.selfie => (
        'Your selfie',
        'So your opponent can see who they are facing.',
      ),
      SetupStep.intro => (
        'Your intro video',
        'Required. Tell us about yourself in 60 seconds. Be serious and '
            'honest - it makes the battle more entertaining and fun to watch. '
            'Your opponent watches it before you battle.',
      ),
      SetupStep.about => ('About me', ''),
    };
    final text = Theme.of(context).textTheme;
    return Column(
      children: [
        _Progress(count: widget.steps.length, at: _i),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 20),
            children: [
              Text(
                title,
                style: text.headlineSmall?.copyWith(
                  fontFamily: context.palette.display,
                  fontWeight: FontWeight.w800,
                ),
              ),
              if (sub.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(sub, style: text.bodyMedium?.copyWith(height: 1.4)),
              ],
              const SizedBox(height: 24),
              ..._stepBody(context, step),
              if (_error != null) ...[
                const SizedBox(height: 16),
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              NeonActionButton(
                label: 'Continue',
                busy: _busy,
                onPressed: (_canContinue && !_busy) ? _next : null,
              ),
              if (step == SetupStep.about)
                TextButton(
                  onPressed: _busy ? null : () => _next(skip: true),
                  child: const Text('Skip'),
                ),
            ],
          ),
        ),
      ],
    );
  }

  List<Widget> _stepBody(BuildContext context, SetupStep step) {
    void unfocus(PointerDownEvent _) =>
        FocusManager.instance.primaryFocus?.unfocus();
    switch (step) {
      case SetupStep.name:
        return [
          TextField(
            controller: _name,
            autofocus: true,
            textCapitalization: TextCapitalization.words,
            textInputAction: TextInputAction.done,
            maxLength: 30,
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) => _canContinue ? _next() : null,
            onTapOutside: unfocus,
            decoration: const InputDecoration(hintText: 'e.g. Mike'),
          ),
        ];
      case SetupStep.location:
        return [
          Text('City & State', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          TextField(
            controller: _city,
            textCapitalization: TextCapitalization.words,
            textInputAction: TextInputAction.done,
            maxLength: 50,
            onTapOutside: unfocus,
            decoration: const InputDecoration(hintText: 'e.g. San Diego, CA'),
          ),
          const SizedBox(height: 12),
          Text('Country', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          CountryField(
            code: _country,
            onPicked: (c) => setState(() => _country = c),
          ),
        ];
      case SetupStep.selfie:
        return const [SelfieCard(bare: true)];
      case SetupStep.intro:
        return const [IntroVideoCard(bare: true)];
      case SetupStep.about:
        return [
          TextField(
            controller: _about,
            maxLines: 4,
            maxLength: 280,
            onTapOutside: unfocus,
            decoration: const InputDecoration(
              hintText:
                  'Who you are, what you do, something embarrassing - '
                  'whatever you want to share.',
            ),
          ),
        ];
    }
  }

  Widget _buildDone(BuildContext context) {
    final p = context.palette;
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        children: [
          const Spacer(),
          Image.asset('assets/branding/bully_league_crown.png', height: 90),
          const SizedBox(height: 24),
          Text(
            'Setup complete',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontFamily: p.display,
              fontSize: 34,
              height: 1.1,
              fontVariations: const [FontVariation('wght', 900)],
            ),
          ),
          const SizedBox(height: 12),
          Text(
            'You may now enter The Bully League.',
            textAlign: TextAlign.center,
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(height: 1.4),
          ),
          const Spacer(),
          NeonActionButton(
            label: 'Enter The Bully League',
            onPressed: () => Navigator.of(context).pop(true),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

class _Progress extends StatelessWidget {
  const _Progress({required this.count, required this.at});
  final int count;
  final int at;

  @override
  Widget build(BuildContext context) {
    final pink = Theme.of(context).colorScheme.primary;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
      child: Row(
        children: [
          for (var i = 0; i < count; i++)
            Expanded(
              child: Container(
                height: 4,
                margin: const EdgeInsets.symmetric(horizontal: 2),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(2),
                  color: i <= at ? pink : Colors.white.withValues(alpha: 0.15),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
