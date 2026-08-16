import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

/// In-app support/contact form (Build Order step 9b) - CLAUDE.md's Support
/// & Launch Strategy decision explicitly calls for this over a plain email
/// link, both to route requests through the app and to satisfy app-store
/// listing requirements for a support contact. Reviewed via the Firebase
/// console, same pattern as reports/banAppeals - no custom admin UI, no
/// client read rule.
class SupportScreen extends StatefulWidget {
  const SupportScreen({super.key});

  @override
  State<SupportScreen> createState() => _SupportScreenState();
}

/// Deliberately does NOT offer a refund category.
///
/// Two reasons. Nothing in the app takes money yet, so it advertised a
/// process that did not exist. And once subscriptions do ship, purchases go
/// through Apple and Google - THEY process refunds, not us - so a refund
/// option here would promise something we cannot deliver and route people
/// away from the only place that can actually help them.
///
/// Options in a list read as suggestions, so anything listed should be
/// something we want asked. A billing category is worth adding when there
/// is billing, and its answer will be "here is the store's refund process".
enum _SupportCategory {
  generalQuestion('general_question', 'General question'),
  bugReport('bug_report', 'Bug report'),
  accountIssue('account_issue', 'Account issue'),
  other('other', 'Other');

  const _SupportCategory(this.value, this.label);

  final String value;
  final String label;
}

class _SupportScreenState extends State<SupportScreen> {
  _SupportCategory _category = _SupportCategory.generalQuestion;
  final _messageController = TextEditingController();
  bool _submitting = false;
  String? _resultMessage;

  @override
  void dispose() {
    _messageController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_messageController.text.trim().isEmpty) return;
    setState(() {
      _submitting = true;
      _resultMessage = null;
    });
    try {
      await FirebaseFirestore.instance.collection('supportRequests').add({
        'uid': FirebaseAuth.instance.currentUser!.uid,
        'category': _category.value,
        'message': _messageController.text.trim(),
        'status': 'open',
        'createdAt': FieldValue.serverTimestamp(),
      });
      if (mounted) setState(() => _resultMessage = 'Request submitted. We\'ll get back to you.');
    } catch (e) {
      if (mounted) setState(() => _resultMessage = 'Failed to submit: $e');
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final submitted = _resultMessage != null && _resultMessage!.startsWith('Request submitted');
    return Scaffold(
      appBar: AppBar(title: const Text('Support & Feedback')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: submitted
            ? Center(child: Text(_resultMessage!, textAlign: TextAlign.center))
            : SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'Questions, bugs, or anything else - let us know.',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                    const SizedBox(height: 24),
                    DropdownButtonFormField<_SupportCategory>(
                      initialValue: _category,
                      decoration: const InputDecoration(labelText: 'Category'),
                      items: _SupportCategory.values
                          .map((c) => DropdownMenuItem(value: c, child: Text(c.label)))
                          .toList(),
                      onChanged: (value) {
                        if (value != null) setState(() => _category = value);
                      },
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: _messageController,
                      maxLines: 5,
                      decoration: const InputDecoration(labelText: 'Message'),
                    ),
                    const SizedBox(height: 24),
                    if (_resultMessage != null) ...[
                      Text(_resultMessage!, style: const TextStyle(color: Colors.red)),
                      const SizedBox(height: 16),
                    ],
                    FilledButton(
                      onPressed: _submitting ? null : _submit,
                      child: _submitting
                          ? const SizedBox(
                              height: 20,
                              width: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text('Submit'),
                    ),
                  ],
                ),
              ),
      ),
    );
  }
}
