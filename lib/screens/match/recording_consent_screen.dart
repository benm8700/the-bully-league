import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

/// Explicit, separate consent step required before recording a match -
/// several states (incl. California) require ALL-PARTY consent to record
/// video calls, and this must be its own affirmative action, not buried in
/// the Terms of Service. See CLAUDE.md's "Recording Consent" legal item.
///
/// For everyday (ranked) matches it ALSO carries the optional "let people watch
/// this battle live" opt-in ([showLiveWatchOptIn]). Spectating is otherwise
/// restricted to tournament matches on purpose - two random strangers didn't
/// sign up for a live audience - so an everyday match only becomes watchable
/// live if BOTH players turn this on. The choice is saved as
/// users/{uid}.liveWatchOptIn and read at pairing time.
///
/// PLACEHOLDER COPY: written to be clear and functional for testing, but
/// NOT yet reviewed by a lawyer. Needs real legal review before launch -
/// see CLAUDE.md.
class RecordingConsentScreen extends StatefulWidget {
  const RecordingConsentScreen({super.key, this.showLiveWatchOptIn = false});

  /// Whether to show the optional "let people watch live" opt-in (everyday
  /// ranked matches only; tournaments are already opted in by entering, and
  /// friend/practice aren't spectatable).
  final bool showLiveWatchOptIn;

  @override
  State<RecordingConsentScreen> createState() => _RecordingConsentScreenState();
}

class _RecordingConsentScreenState extends State<RecordingConsentScreen> {
  bool _consentChecked = false;
  bool _liveWatch = false;

  @override
  void initState() {
    super.initState();
    if (widget.showLiveWatchOptIn) _loadPref();
  }

  /// Default the switch to the player's last choice, so it's a remembered
  /// preference they can still change per match.
  Future<void> _loadPref() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    try {
      final snap =
          await FirebaseFirestore.instance.collection('users').doc(uid).get();
      final v = snap.data()?['liveWatchOptIn'] == true;
      if (mounted) setState(() => _liveWatch = v);
    } catch (_) {
      // Leave it off; a failed read shouldn't flip someone live by accident.
    }
  }

  /// Persist the choice before continuing, so pairing can read it. A plain
  /// write to a non-protected user field.
  Future<void> _savePref() async {
    if (!widget.showLiveWatchOptIn) return;
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    try {
      await FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .set({'liveWatchOptIn': _liveWatch}, SetOptions(merge: true));
    } catch (_) {
      // Best-effort: never block starting a match on this preference write.
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Recording Consent')),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(24, 24, 24, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Icon(Icons.videocam, size: 48),
                  const SizedBox(height: 16),
                  Text(
                    'This match will be recorded',
                    style: text.headlineSmall,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'Both you and your opponent will be recorded for the full duration of '
                    'this match. By continuing, you confirm that:',
                  ),
                  const SizedBox(height: 12),
                  const _ConsentBullet(
                    'You consent to being recorded, on video and audio, for this match.',
                  ),
                  const _ConsentBullet(
                    'The Bully League may use and post this recording publicly - '
                    'on our website, our social media, and in our promotional / '
                    'marketing content - including as a highlight. You can opt a '
                    'specific clip out later from My Battles.',
                  ),
                  const _ConsentBullet(
                    'The raw recording is kept for a limited time (see Privacy Policy) '
                    'and then deleted unless it was posted as a highlight.',
                  ),
                  // OPTIONAL live-watch opt-in (everyday matches only). Off by
                  // default, and only takes effect if the opponent opts in too.
                  if (widget.showLiveWatchOptIn) ...[
                    const SizedBox(height: 24),
                    const Divider(),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Icon(Icons.live_tv_outlined,
                            color: Theme.of(context).colorScheme.primary),
                        const SizedBox(width: 8),
                        Text('Go live (optional)', style: text.titleMedium),
                      ],
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      "Off by default. Turn this on and signed-in viewers in the "
                      "app can watch this battle as it happens. It only goes "
                      "live if your opponent turns it on too - and the "
                      "recording and crowd vote work the same either way.",
                    ),
                    SwitchListTile(
                      value: _liveWatch,
                      onChanged: (v) => setState(() => _liveWatch = v),
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Let people watch this battle live'),
                    ),
                  ],
                ],
              ),
            ),
          ),
          // SafeArea(bottom) keeps the buttons clear of the system gesture
          // bar - without it, on a gesture-nav phone the "I Agree" / Decline
          // row sits inside the home-gesture inset and taps hit the launcher
          // instead (found on a real S22, 2026-09-01).
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  CheckboxListTile(
                    value: _consentChecked,
                    onChanged: (value) =>
                        setState(() => _consentChecked = value ?? false),
                    controlAffinity: ListTileControlAffinity.leading,
                    title: const Text(
                        'I understand and consent to being recorded.'),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () => Navigator.of(context).pop(false),
                          child: const Text('Decline'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: FilledButton(
                          onPressed: _consentChecked
                              ? () async {
                                  await _savePref();
                                  if (context.mounted) {
                                    Navigator.of(context).pop(true);
                                  }
                                }
                              : null,
                          child: const Text('I Agree'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ConsentBullet extends StatelessWidget {
  const _ConsentBullet(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('•  '),
          Expanded(child: Text(text)),
        ],
      ),
    );
  }
}
