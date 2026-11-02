import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

/// After a handful of real battles - proof the player has actually used the
/// app - asks ONCE how we can make it more fun. Shown on app open alongside
/// the other MainShell popups. A dismissed or submitted prompt never returns
/// (a `feedbackPrompted` flag on the user doc). Writes to feedback/{id} for
/// console review, same pattern as supportRequests.
class FeedbackPopup {
  /// Battles (wins + losses) before we ask: enough to prove real use, low
  /// enough to catch them while they're engaged. Tunable.
  static const _minBattles = 3;

  static Future<void> maybeShow(BuildContext context) async {
    try {
      final uid = FirebaseAuth.instance.currentUser?.uid;
      if (uid == null) return;
      final ref = FirebaseFirestore.instance.collection('users').doc(uid);
      final snap = await ref.get();
      final data = snap.data();
      if (data == null) return;
      if (data['feedbackPrompted'] == true) return;
      final battles = ((data['wins'] as num?)?.toInt() ?? 0) +
          ((data['losses'] as num?)?.toInt() ?? 0);
      if (battles < _minBattles) return;
      // Marked asked BEFORE showing, so a dismissed dialog or a killed app
      // never re-fires it.
      await ref.set({'feedbackPrompted': true}, SetOptions(merge: true));
      if (!context.mounted) return;
      await showDialog<void>(
        context: context,
        builder: (_) => _FeedbackDialog(uid: uid, battles: battles),
      );
    } catch (_) {
      // A prompt must never break a session.
    }
  }
}

class _FeedbackDialog extends StatefulWidget {
  const _FeedbackDialog({required this.uid, required this.battles});

  final String uid;
  final int battles;

  @override
  State<_FeedbackDialog> createState() => _FeedbackDialogState();
}

class _FeedbackDialogState extends State<_FeedbackDialog> {
  static const _pink = Color(0xFFEA4C6D);
  final _controller = TextEditingController();
  bool _sending = false;
  bool _sent = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _controller.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      await FirebaseFirestore.instance.collection('feedback').add({
        'uid': widget.uid,
        'message': text,
        'battles': widget.battles,
        'createdAt': FieldValue.serverTimestamp(),
      });
      if (mounted) {
        setState(() {
          _sent = true;
          _sending = false;
        });
      }
    } catch (_) {
      // Feedback is nice-to-have, never blocking - close quietly on failure.
      if (mounted) Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_sent) {
      return AlertDialog(
        backgroundColor: const Color(0xFF17131B),
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(22),
          side: const BorderSide(color: _pink, width: 1.4),
        ),
        icon: const Text('🔥', style: TextStyle(fontSize: 42)),
        title: const Text('Thanks!',
            textAlign: TextAlign.center,
            style: TextStyle(
                color: Colors.white, fontWeight: FontWeight.w900, fontSize: 20)),
        content: const Text(
          "We read every one of these. Now get back in there.",
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.white70),
        ),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(context).pop(),
            style: FilledButton.styleFrom(
                backgroundColor: _pink, foregroundColor: Colors.white),
            child: const Text("Let's go",
                style: TextStyle(fontWeight: FontWeight.w800)),
          ),
        ],
      );
    }
    return AlertDialog(
      backgroundColor: const Color(0xFF17131B),
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(22),
        side: BorderSide(color: _pink.withValues(alpha: 0.6), width: 1.4),
      ),
      icon: const Text('🎤', style: TextStyle(fontSize: 38)),
      title: const Text('Enjoying the carnage?',
          textAlign: TextAlign.center,
          style: TextStyle(
              color: Colors.white, fontWeight: FontWeight.w900, fontSize: 20)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            "We want this to be as fun as humanly possible. What would make it "
            "better? Be brutal - it's on brand.",
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white70),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _controller,
            maxLines: 3,
            maxLength: 500,
            autofocus: true,
            style: const TextStyle(color: Colors.white),
            decoration: InputDecoration(
              hintText: 'Tell us what would make it more fun…',
              hintStyle: const TextStyle(color: Colors.white38),
              filled: true,
              fillColor: Colors.white.withValues(alpha: 0.05),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none,
              ),
              counterStyle: const TextStyle(color: Colors.white30),
            ),
          ),
        ],
      ),
      actionsAlignment: MainAxisAlignment.spaceBetween,
      actions: [
        TextButton(
          onPressed: _sending ? null : () => Navigator.of(context).pop(),
          child: const Text('Maybe later',
              style: TextStyle(color: Colors.white54)),
        ),
        FilledButton(
          onPressed: _sending ? null : _send,
          style: FilledButton.styleFrom(
              backgroundColor: _pink, foregroundColor: Colors.white),
          child: Text(_sending ? 'Sending…' : 'Send it',
              style: const TextStyle(fontWeight: FontWeight.w800)),
        ),
      ],
    );
  }
}
