import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../../theme/house_theme.dart';

/// In-app report button (Build Order step 9). Reports feed a review queue
/// that's just Firestore documents browsed via the Firebase console (same
/// "admin uses the console" pattern as profile approval and tournament
/// creation - see CLAUDE.md's Admin/moderation tooling notes), not a
/// custom admin screen.
///
/// This is a comedy-roast platform with an explicit free-speech stance -
/// offensive jokes, insults, and no-holds-barred material are ALLOWED BY
/// DESIGN (see CLAUDE.md's Content Policy & Moderation section). The
/// category copy below is deliberately worded so reporting isn't just "this
/// roast was mean" - it's for things outside the comedy format entirely
/// (deliberate hate/bigotry, sustained targeted bullying, etc.), matching
/// CLAUDE.md's bannable-offense standard ("intentional disruption/bullying
/// NOT in service of comedy").
class ReportScreen extends StatefulWidget {
  const ReportScreen({super.key, required this.reportedUserId, this.matchId});

  final String reportedUserId;
  final String? matchId;

  @override
  State<ReportScreen> createState() => _ReportScreenState();
}

enum _ReportReason {
  harassment('harassment', 'Harassment', 'Targeted, sustained bullying that goes beyond the roast itself'),
  hateSpeech('hate_speech', 'Hate speech',
      'Slurs or attacks meant to demean someone\'s race, religion, gender, etc. - not comedic wordplay'),
  technicalQuality('technical_quality', 'Technical/quality issue', 'Audio, video, or connection problems'),
  inappropriateContent(
      'inappropriate_content', 'Inappropriate content', 'Nudity or explicit visuals, not offensive language'),
  impersonation('impersonation', 'Impersonation', 'Pretending to be someone else');

  const _ReportReason(this.value, this.label, this.description);

  final String value;
  final String label;
  final String description;
}

class _ReportScreenState extends State<ReportScreen> {
  _ReportReason? _selectedReason;
  final _detailsController = TextEditingController();
  bool _submitting = false;
  String? _resultMessage;

  @override
  void dispose() {
    _detailsController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_selectedReason == null) return;
    setState(() {
      _submitting = true;
      _resultMessage = null;
    });
    try {
      await FirebaseFirestore.instance.collection('reports').add({
        'reporterId': FirebaseAuth.instance.currentUser!.uid,
        'reportedUserId': widget.reportedUserId,
        'matchId': widget.matchId,
        'reason': _selectedReason!.value,
        'details': _detailsController.text.trim(),
        'status': 'pending',
        'createdAt': FieldValue.serverTimestamp(),
      });
      if (mounted) setState(() => _resultMessage = 'Report submitted. Thanks for helping keep things fair.');
    } catch (e) {
      if (mounted) setState(() => _resultMessage = 'Failed to submit report: $e');
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final submitted = _resultMessage != null && _resultMessage!.startsWith('Report submitted');
    return Scaffold(
      appBar: AppBar(title: const Text('Report')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: submitted
            ? Center(child: Text(_resultMessage!, textAlign: TextAlign.center))
            : SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'Roasting is the point of this app - offensive jokes and hard-hitting '
                      'insults are expected and allowed. Report this only for something '
                      'outside that: deliberate hate, targeted bullying, or a technical/'
                      'content problem.',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                    const SizedBox(height: 24),
                    RadioGroup<_ReportReason>(
                      groupValue: _selectedReason,
                      onChanged: (value) => setState(() => _selectedReason = value),
                      child: Column(
                        children: _ReportReason.values
                            .map(
                              (reason) => RadioListTile<_ReportReason>(
                                value: reason,
                                title: Text(reason.label),
                                subtitle: Text(reason.description),
                              ),
                            )
                            .toList(),
                      ),
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: _detailsController,
                      maxLines: 3,
                      decoration: const InputDecoration(labelText: 'Additional details (optional)'),
                    ),
                    const SizedBox(height: 24),
                    if (_resultMessage != null) ...[
                      Text(_resultMessage!, style: const TextStyle(color: House.alarm)),
                      const SizedBox(height: 16),
                    ],
                    FilledButton(
                      onPressed: (_selectedReason != null && !_submitting) ? _submit : null,
                      child: _submitting
                          ? const SizedBox(
                              height: 20,
                              width: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text('Submit Report'),
                    ),
                  ],
                ),
              ),
      ),
    );
  }
}
