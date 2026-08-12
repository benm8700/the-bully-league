import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';

/// DEV/TEST ONLY - calls the debugFinalizeMatch Cloud Function, which
/// bypasses the real 24h voting window so the rating pipeline (Build Order
/// step 6) can be verified without waiting a real day. See
/// functions/index.js's debugFinalizeMatch for the matching server-side
/// warning about this not being access-controlled yet.
class FinalizeTestScreen extends StatefulWidget {
  const FinalizeTestScreen({super.key});

  @override
  State<FinalizeTestScreen> createState() => _FinalizeTestScreenState();
}

class _FinalizeTestScreenState extends State<FinalizeTestScreen> {
  final _matchIdController = TextEditingController();
  bool _submitting = false;
  String? _resultMessage;

  @override
  void dispose() {
    _matchIdController.dispose();
    super.dispose();
  }

  Future<void> _finalize() async {
    final matchId = _matchIdController.text.trim();
    if (matchId.isEmpty) return;
    setState(() {
      _submitting = true;
      _resultMessage = null;
    });

    try {
      final callable = FirebaseFunctions.instance.httpsCallable('debugFinalizeMatch');
      final result = await callable.call({'matchId': matchId});
      setState(() => _resultMessage = result.data.toString());
    } on FirebaseFunctionsException catch (e) {
      setState(() => _resultMessage = 'Failed: ${e.message ?? e.code}');
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Finalize Match (test)')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Force-finalizes a match\'s votes and applies rating changes '
              'immediately, bypassing the real 24h window. Dev/test only.',
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _matchIdController,
              decoration: const InputDecoration(labelText: 'Match ID'),
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _submitting ? null : _finalize,
              child: _submitting
                  ? const SizedBox(
                      height: 20,
                      width: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Finalize'),
            ),
            if (_resultMessage != null) ...[
              const SizedBox(height: 16),
              Text(_resultMessage!),
            ],
          ],
        ),
      ),
    );
  }
}
