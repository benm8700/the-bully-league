import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../info/rules_screen.dart';

/// A one-time content-policy + age acknowledgement, shown the first time an
/// account opens the app (see `_AccountStatusGate` in app.dart, which gates on
/// the `contentPolicyAcceptedAt` flag). This is the "mature-content consent at
/// signup" CLAUDE.md decided but never built - implemented at first app entry
/// rather than mid-signup, so it also catches every existing account on their
/// next open.
///
/// DELIBERATELY DEADPAN. The brand voice lives everywhere else; a consent gate
/// has to be uncoerced and clear (Accept plainly, Decline neutrally - no
/// shaming the decline path, which would both invalidate the consent and be a
/// self-inflicted App Store review risk on the exact screen meant to show the
/// content/age handling is responsible).
///
/// ACCEPT writes the flag and the user-doc stream in _AccountStatusGate swaps
/// straight into the app (Battle tab). DECLINE does NOT sign you out or lock
/// the account - it simply holds you here: you cannot proceed into an app
/// whose whole premise is this content without agreeing to it, but you can
/// come back and accept any time (or close the app).
///
/// The copy is a FUNCTIONAL PLACEHOLDER, not lawyer-reviewed - same standing
/// caveat as the /legal page. Real legal review before any public launch.
class ContentPolicyScreen extends StatefulWidget {
  const ContentPolicyScreen({super.key, required this.uid});

  final String uid;

  @override
  State<ContentPolicyScreen> createState() => _ContentPolicyScreenState();
}

class _ContentPolicyScreenState extends State<ContentPolicyScreen> {
  bool _submitting = false;
  bool _declined = false;

  Future<void> _accept() async {
    setState(() => _submitting = true);
    try {
      // A plain client write to a non-protected field, recorded with a server
      // timestamp so there is a real consent record. Once it lands, the user-
      // doc stream in _AccountStatusGate re-renders straight into the app
      // (Battle tab) - no navigation needed here.
      await FirebaseFirestore.instance
          .collection('users')
          .doc(widget.uid)
          .set(
        {'contentPolicyAcceptedAt': FieldValue.serverTimestamp()},
        SetOptions(merge: true),
      );
    } catch (_) {
      // Let them try again rather than trapping them on a spinner.
      if (mounted) setState(() => _submitting = false);
    }
  }

  void _decline() {
    // No sign-out, no lockout - just hold them here. They can't proceed
    // without accepting, but the account is untouched and they can accept
    // whenever they like.
    setState(() => _declined = true);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            24,
            24,
            24,
            16 + MediaQuery.of(context).padding.bottom,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SizedBox(height: 12),
                      Icon(Icons.local_fire_department,
                          size: 44, color: scheme.primary),
                      const SizedBox(height: 16),
                      Text(
                        'Before you roast',
                        style: theme.textTheme.headlineMedium,
                      ),
                      const SizedBox(height: 20),
                      Text(
                        'You must be 18 or older to use The Bully League.',
                        style: theme.textTheme.titleMedium,
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'By continuing, you confirm you are 18 or older. The '
                        'Bully League is a comedy roast platform — you '
                        'will be the target of offensive, crude, and '
                        'politically incorrect jokes, including material about '
                        'race, sex, gender, orientation and more, and you '
                        'accept that as part of the format.',
                        style: theme.textTheme.bodyLarge,
                      ),
                      const SizedBox(height: 14),
                      Text(
                        'This does not cover deliberate hate or harassment '
                        'meant to genuinely demean you rather than get a laugh '
                        '— that is never allowed, and you can always '
                        'report it.',
                        style: theme.textTheme.bodyLarge,
                      ),
                      const SizedBox(height: 20),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton(
                          onPressed: () => Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => const RulesScreen(),
                            ),
                          ),
                          child: const Text('Read the full rules'),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              // Shown only after a decline: explains why they're still here,
              // without shaming them for declining.
              if (_declined) ...[
                const SizedBox(height: 4),
                Text(
                  'You need to accept this to use The Bully League — it is the '
                  'whole format. Tap "I\'m in" when you\'re ready.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(color: scheme.primary),
                ),
              ],
              const SizedBox(height: 8),
              FilledButton(
                onPressed: _submitting ? null : _accept,
                style: FilledButton.styleFrom(
                  minimumSize: const Size(0, 52),
                ),
                child: _submitting
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text("I'm in"),
              ),
              const SizedBox(height: 10),
              TextButton(
                onPressed: _submitting ? null : _decline,
                child: const Text('Not for me'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
