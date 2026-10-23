import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../core/services/lobby_chat_service.dart';
import '../theme/app_theme.dart';

/// The Main Stage viewers' LOBBY chat - the whole crowd's room, where the
/// audience talks about the battles before, during and between them. Public
/// (any signed-in viewer), moderated + rate-limited on the one write path, and
/// wiped when the show ends. Give it a bounded height (place in an Expanded)
/// when [expand] is true.
class LobbyChat extends StatefulWidget {
  const LobbyChat({
    super.key,
    required this.tournamentId,
    this.service,
    this.expand = false,
  });

  final String tournamentId;
  final LobbyChatService? service;
  final bool expand;

  @override
  State<LobbyChat> createState() => _LobbyChatState();
}

class _LobbyChatState extends State<LobbyChat> {
  late final LobbyChatService _service = widget.service ?? LobbyChatService();
  final TextEditingController _controller = TextEditingController();
  final ScrollController _scroll = ScrollController();
  final String _myUid = FirebaseAuth.instance.currentUser?.uid ?? '';

  bool _sending = false;
  String? _error;

  // Created ONCE, not per build, so the keyboard doesn't steal focus / reset.
  late final Stream<List<LobbyChatMessage>> _messages =
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
      final msg = e.toString();
      final i = msg.indexOf(']');
      if (mounted) {
        setState(() =>
            _error = i >= 0 ? msg.substring(i + 1).trim() : 'Could not send.');
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final pink = context.palette.accent;
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        color: Colors.black.withValues(alpha: 0.3),
        border: Border.all(color: pink.withValues(alpha: 0.35)),
      ),
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.forum, size: 18, color: pink),
              const SizedBox(width: 8),
              Text('The crowd',
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      color: pink, fontWeight: FontWeight.w800)),
            ],
          ),
          const SizedBox(height: 2),
          Text('Talk about the battles with everyone else watching.',
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
                    hintText: 'Say something to the crowd…',
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

  Widget _messageArea(ColorScheme cs) {
    final list = StreamBuilder<List<LobbyChatMessage>>(
      stream: _messages,
      builder: (context, snap) {
        final msgs = snap.data ?? const <LobbyChatMessage>[];
        if (snap.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_scroll.hasClients) {
            _scroll.jumpTo(_scroll.position.maxScrollExtent);
          }
        });
        return ListView.builder(
          controller: _scroll,
          itemCount: msgs.length + 1,
          itemBuilder: (context, i) =>
              i == 0 ? _roomIntro(cs) : _bubble(msgs[i - 1], cs),
        );
      },
    );
    return widget.expand
        ? Expanded(child: list)
        : SizedBox(height: 220, child: list);
  }

  Widget _roomIntro(ColorScheme cs) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 2, 4, 8),
        child: Text(
          'Welcome to the crowd — keep it comedy, not hate.',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: cs.onSurfaceVariant,
            fontSize: 12,
            fontStyle: FontStyle.italic,
            height: 1.3,
          ),
        ),
      );

  Widget _bubble(LobbyChatMessage m, ColorScheme cs) {
    final mine = m.uid == _myUid;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Text.rich(
        TextSpan(children: [
          TextSpan(
            text: '${mine ? 'You' : m.username}: ',
            style: TextStyle(
              color: mine ? context.palette.accent : cs.onSurfaceVariant,
              fontWeight: FontWeight.w800,
            ),
          ),
          TextSpan(text: m.text, style: const TextStyle(color: Colors.white)),
        ]),
        style: const TextStyle(fontSize: 13, height: 1.3),
      ),
    );
  }
}
