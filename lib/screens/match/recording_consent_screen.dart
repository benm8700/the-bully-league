import 'package:flutter/material.dart';

/// Explicit, separate consent step required before recording a match -
/// several states (incl. California) require ALL-PARTY consent to record
/// video calls, and this must be its own affirmative action, not buried in
/// the Terms of Service. See CLAUDE.md's "Recording Consent" legal item.
///
/// PLACEHOLDER COPY: written to be clear and functional for testing, but
/// NOT yet reviewed by a lawyer. Needs real legal review before launch -
/// see CLAUDE.md.
class RecordingConsentScreen extends StatefulWidget {
  const RecordingConsentScreen({super.key});

  @override
  State<RecordingConsentScreen> createState() => _RecordingConsentScreenState();
}

class _RecordingConsentScreenState extends State<RecordingConsentScreen> {
  bool _consentChecked = false;

  @override
  Widget build(BuildContext context) {
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
                    style: Theme.of(context).textTheme.headlineSmall,
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
                    'If this is a ranked or tournament match, the recording may be posted '
                    'publicly on The Bully League\'s website or social media if it\'s '
                    'selected as a highlight.',
                  ),
                  const _ConsentBullet(
                    'The raw recording is kept for a limited time (see Privacy Policy) '
                    'and then deleted unless it was posted as a highlight.',
                  ),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                CheckboxListTile(
                  value: _consentChecked,
                  onChanged: (value) => setState(() => _consentChecked = value ?? false),
                  controlAffinity: ListTileControlAffinity.leading,
                  title: const Text('I understand and consent to being recorded.'),
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
                        onPressed:
                            _consentChecked ? () => Navigator.of(context).pop(true) : null,
                        child: const Text('I Agree'),
                      ),
                    ),
                  ],
                ),
              ],
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
