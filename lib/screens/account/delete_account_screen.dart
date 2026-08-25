import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../../theme/house_theme.dart';

/// User-initiated account and data deletion (CCPA - see CLAUDE.md's
/// Compliance / Account Management item, which makes this a V1 requirement
/// rather than a later addition).
///
/// The screen is deliberately explicit about what survives deletion. Two
/// things do, and a user who discovers them afterwards would rightly feel
/// misled:
///  - Highlight clips already published, which were consented to under the
///    Terms at the time and are already publicly distributed.
///  - The record that their past matches happened, because the opponent's
///    rating history depends on them. Their name is removed from those.
///
/// Saying that plainly up front is both the honest thing and the safer
/// one - an app store reviewer asking "what does delete actually delete?"
/// gets an answer on the screen itself.
class DeleteAccountScreen extends StatefulWidget {
  const DeleteAccountScreen({super.key});

  @override
  State<DeleteAccountScreen> createState() => _DeleteAccountScreenState();
}

class _DeleteAccountScreenState extends State<DeleteAccountScreen> {
  final _confirmController = TextEditingController();
  bool _busy = false;
  String? _error;

  static const _confirmWord = 'DELETE';

  @override
  void dispose() {
    _confirmController.dispose();
    super.dispose();
  }

  bool get _canDelete =>
      !_busy && _confirmController.text.trim().toUpperCase() == _confirmWord;

  Future<void> _delete() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await FirebaseFunctions.instance
          .httpsCallable('deleteMyAccount')
          .call<Map<String, dynamic>>();
      // The server deletes the auth account itself, so this session is
      // already void; signing out just clears local state and lets
      // AuthGate return to the signed-out screen.
      await FirebaseAuth.instance.signOut().catchError((_) {});
      if (!mounted) return;
      Navigator.of(context).popUntil((route) => route.isFirst);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = 'Could not delete your account: $e';
      });
    }
  }

  Future<void> _confirmThenDelete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete your account?'),
        content: const Text(
          'This permanently deletes your profile, your photos and your '
          'unpublished match footage. It cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: FilledButton.styleFrom(backgroundColor: House.alarm),
            child: const Text('Delete forever'),
          ),
        ],
      ),
    );
    if (confirmed == true) await _delete();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Delete Account')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const Icon(Icons.warning_amber_rounded, size: 48, color: House.alarm),
          const SizedBox(height: 16),
          Text(
            'Deleting your account is permanent',
            style: Theme.of(context).textTheme.headlineSmall,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),
          _Section(
            title: 'What gets deleted',
            icon: Icons.delete_outline,
            items: const [
              'Your profile: username, bio, interests and anything else you wrote.',
              'Your photos.',
              'Your sign-in details, so you can no longer log in.',
              'Your own footage from matches that were never published.',
              'Any match you are currently queued for.',
            ],
          ),
          const SizedBox(height: 20),
          _Section(
            title: 'What stays, and why',
            icon: Icons.info_outline,
            items: const [
              'Highlight clips already posted publicly. You agreed to this when '
                  'they were posted, and they have already been shared - deleting '
                  'your account here does not remove a post from social media.',
              'The record that your past matches happened, without your name on '
                  'them. Your opponents\' records and rankings depend on those '
                  'results, so removing them would change other people\'s history.',
              'Votes you cast on other people\'s matches, which decided those '
                  'results.',
              'Any moderation reports involving your account.',
            ],
          ),
          const SizedBox(height: 28),
          Text(
            'Type $_confirmWord to confirm',
            style: Theme.of(context).textTheme.labelLarge,
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _confirmController,
            enabled: !_busy,
            textCapitalization: TextCapitalization.characters,
            decoration: const InputDecoration(border: OutlineInputBorder()),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 20),
          FilledButton(
            onPressed: _canDelete ? _confirmThenDelete : null,
            style: FilledButton.styleFrom(backgroundColor: House.alarm),
            child: _busy
                ? const SizedBox(
                    height: 20,
                    width: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Delete my account'),
          ),
          if (_error != null) ...[
            const SizedBox(height: 16),
            Text(_error!, style: const TextStyle(color: House.alarm)),
          ],
          const SizedBox(height: 24),
          Text(
            'If you only want to take a break, you can simply sign out instead.',
            style: Theme.of(context).textTheme.bodySmall,
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.icon, required this.items});

  final String title;
  final IconData icon;
  final List<String> items;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, size: 20),
            const SizedBox(width: 8),
            Text(title, style: Theme.of(context).textTheme.titleMedium),
          ],
        ),
        const SizedBox(height: 8),
        for (final item in items)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('•  '),
                Expanded(child: Text(item)),
              ],
            ),
          ),
      ],
    );
  }
}
