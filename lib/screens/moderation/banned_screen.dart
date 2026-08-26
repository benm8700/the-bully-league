import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import 'package:provider/provider.dart';

import '../../core/services/auth_service.dart';
import '../support/support_screen.dart';

/// CLAUDE.md's Ban appeal decision: a simple appeal/dispute flow for
/// banned users, even though the underlying ban decision stays admin
/// discretion (Trust & Safety / Moderation Workflow section) - this gives
/// recourse to contest without guaranteeing reversal. Shown by AuthGate
/// in place of HomeScreen whenever the signed-in user's accountStatus is
/// 'banned' - see app.dart.
class BannedScreen extends StatefulWidget {
  const BannedScreen({super.key});

  @override
  State<BannedScreen> createState() => _BannedScreenState();
}

class _BannedScreenState extends State<BannedScreen> {
  final _messageController = TextEditingController();
  bool _submitting = false;
  bool _submitted = false;
  String? _errorMessage;

  @override
  void dispose() {
    _messageController.dispose();
    super.dispose();
  }

  Future<void> _submitAppeal() async {
    if (_messageController.text.trim().isEmpty) return;
    setState(() {
      _submitting = true;
      _errorMessage = null;
    });
    try {
      await FirebaseFirestore.instance.collection('banAppeals').add({
        'uid': FirebaseAuth.instance.currentUser!.uid,
        'message': _messageController.text.trim(),
        'status': 'pending',
        'createdAt': FieldValue.serverTimestamp(),
      });
      if (mounted) setState(() => _submitted = true);
    } catch (e) {
      if (mounted) setState(() => _errorMessage = 'Failed to submit appeal: $e');
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final authService = context.read<AuthService>();
    return Scaffold(
      appBar: AppBar(
        title: const Text('Account banned'),
        actions: [
          // Kept separate from the appeal form below - a banned account
          // may have an unrelated need (billing, a genuine account issue)
          // that shouldn't be limited to only contesting the ban itself.
          IconButton(
            icon: const Icon(Icons.help_outline),
            tooltip: 'Support & Feedback',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const SupportScreen()),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.logout),
            tooltip: 'Sign out',
            onPressed: () => authService.signOut(),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: _submitted
            ? const Center(
                child: Text(
                  'Appeal submitted. We\'ll review it - this doesn\'t guarantee the ban '
                  'gets reversed, but someone will take a look.',
                  textAlign: TextAlign.center,
                ),
              )
            : SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'Your account has been banned.',
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      'If you think this was a mistake, you can submit an appeal below. '
                      'Ban decisions are made case by case and appeals don\'t guarantee '
                      'reversal, but every appeal gets reviewed.',
                    ),
                    const SizedBox(height: 24),
                    TextField(
                      controller: _messageController,
                      maxLines: 5,
                      decoration: const InputDecoration(
                        labelText: 'Why should this ban be reconsidered?',
                      ),
                    ),
                    const SizedBox(height: 16),
                    if (_errorMessage != null) ...[
                      Text(_errorMessage!, style: const TextStyle(color: Color(0xFFE05252))),
                      const SizedBox(height: 16),
                    ],
                    FilledButton(
                      onPressed: _submitting ? null : _submitAppeal,
                      child: _submitting
                          ? const SizedBox(
                              height: 20,
                              width: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text('Submit Appeal'),
                    ),
                  ],
                ),
              ),
      ),
    );
  }
}
