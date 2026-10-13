import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../core/services/judge_chat_service.dart';
import '../theme/app_theme.dart';

/// The Main Stage judges' private chat - the panel's green room, before, during
/// and after the battle. Lives on the judge's Main Stage screen. Judges-only
/// (enforced server-side + in firestore.rules); moderated and rate-limited on
/// the one write path. A bounded, self-contained panel so it can sit inside the
/// screen's scroll view.
class JudgeChat extends StatefulWidget {
  const JudgeChat({
    super.key,
    required this.tournamentId,
    this.service,
    this.expand = false,
  });

  final String tournamentId;
  final JudgeChatService? service;

  /// When true, the message list fills all available height (input + send pin
  /// to the bottom) - the widget must be given a bounded height (e.g. placed in
  /// an Expanded). When false, it is a fixed-height panel for a scroll view.
  final bool expand;

  @override
  State<JudgeChat> createState() => _JudgeChatState();
}

class _JudgeChatState extends State<JudgeChat> {
  late final JudgeChatService _service = widget.service ?? JudgeChatService();
  final TextEditingController _controller = TextEditingController();
  final ScrollController _scroll = ScrollController();
  final String _myUid = FirebaseAuth.instance.currentUser?.uid ?? '';

  bool _sending = false;
  String? _error;

  // Created ONCE, not per build: a fresh stream each build would reset the
  // StreamBuilder to "waiting", rebuild the whole panel and steal focus from
  // the text field the instant the keyboard opens (the flash-then-close bug).
  late final Stream<List<JudgeChatMessage>> _messages =
      _service.watch(widget.tournamentId);

  @override
  void dispose() {
    _controller.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _controller.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      await _service.post(widget.tournamentId, text);
      _controller.clear();
    } on Exception catch (e) {
      // Surface the server's reason (too fast / blocked content) plainly.
      final msg = e.toString();
      final i = msg.indexOf(']');
      if (mounted) {
        setState(() => _error = i >= 0 ? msg.substring(i + 1).trim() : 'Could not send.');
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final gold = context.palette.reward;
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        color: Colors.black.withValues(alpha: 0.3),
        border: Border.all(color: gold.withValues(alpha: 0.35)),
      ),
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.forum, size: 18, color: gold),
              const SizedBox(width: 8),
              Text("Judges' room",
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      color: gold, fontWeight: FontWeight.w800)),
            ],
          ),
          const SizedBox(height: 2),
          Text('Private to the panel — talk it out before, during and after.',
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: cs.onSurfaceVariant)),
          const SizedBox(height: 10),
          _messageArea(cs),
          if (_error != null) ...[
            const SizedBox(height: 6),
            Text(_error!,
                style: TextStyle(color: context.palette.live, fontSize: 12)),
          ],
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _controller,
                  minLines: 1,
                  maxLines: 3,
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => _send(),
                  decoration: const InputDecoration(
                    hintText: 'Message the panel…',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filled(
                onPressed: _sending ? null : _send,
                icon: _sending
                    ? const SizedBox(
                        height: 18,
                        width: 18,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.send),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// The scrolling message list - flexes to fill when [JudgeChat.expand], else
  /// a fixed-height panel suitable for a scroll view.
  Widget _messageArea(ColorScheme cs) {
    final list = StreamBuilder<List<JudgeChatMessage>>(
      stream: _messages,
      builder: (context, snap) {
        final msgs = snap.data ?? const <JudgeChatMessage>[];
        if (snap.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        if (msgs.isEmpty) {
          return Center(
            child: Text('No messages yet. Say hi to the panel.',
                style: TextStyle(color: cs.onSurfaceVariant)),
          );
        }
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_scroll.hasClients) {
            _scroll.jumpTo(_scroll.position.maxScrollExtent);
          }
        });
        return ListView.builder(
          controller: _scroll,
          itemCount: msgs.length,
          itemBuilder: (context, i) => _bubble(msgs[i], cs),
        );
      },
    );
    return widget.expand
        ? Expanded(child: list)
        : SizedBox(height: 220, child: list);
  }

  Widget _bubble(JudgeChatMessage m, ColorScheme cs) {
    final mine = m.uid == _myUid;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Column(
        crossAxisAlignment:
            mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          Text(mine ? 'You' : m.username,
              style: TextStyle(
                  color: cs.onSurfaceVariant,
                  fontSize: 11,
                  fontWeight: FontWeight.w700)),
          const SizedBox(height: 1),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: mine
                  ? context.palette.reward.withValues(alpha: 0.18)
                  : Colors.white.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(m.text, style: const TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }
}
