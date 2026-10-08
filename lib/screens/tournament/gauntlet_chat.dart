import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../../core/services/lobby_service.dart';
import '../moderation/report_screen.dart';

/// The gauntlet's live, ephemeral chat as a self-contained block: the message
/// list (Expanded) plus the composer. Reused by the lobby, the command centre
/// (Judge screen) and the waiting view, so wherever you are during the event
/// there's one shared room open (the chat is wiped when the gauntlet ends).
///
/// Posting goes through the moderated [LobbyService] callable; reads are a
/// plain Firestore listener. Long-press a message to report it.
class GauntletChat extends StatefulWidget {
  const GauntletChat({super.key, required this.tournamentId});

  final String tournamentId;

  @override
  State<GauntletChat> createState() => _GauntletChatState();
}

class _GauntletChatState extends State<GauntletChat> {
  final _service = LobbyService();
  final _controller = TextEditingController();
  bool _sending = false;

  String? get _myUid => FirebaseAuth.instance.currentUser?.uid;

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
      await _service.post(widget.tournamentId, text);
      _controller.clear();
    } on FirebaseFunctionsException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.message ?? "Couldn't post that.")),
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Couldn't post that - try again.")),
        );
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Expanded(child: _ChatList(tournamentId: widget.tournamentId, myUid: _myUid)),
        _Composer(controller: _controller, sending: _sending, onSend: _send),
      ],
    );
  }
}

class _ChatList extends StatelessWidget {
  const _ChatList({required this.tournamentId, required this.myUid});

  final String tournamentId;
  final String? myUid;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection('tournaments')
          .doc(tournamentId)
          .collection('lobbyChat')
          .orderBy('createdAt', descending: true)
          .limit(100)
          .snapshots(),
      builder: (context, snapshot) {
        final docs = snapshot.data?.docs ?? const [];
        if (docs.isEmpty) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                'Quiet in here. Say something to the room.\n'
                'Chat clears when the gauntlet ends.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          );
        }
        return ListView.builder(
          reverse: true,
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          itemCount: docs.length,
          itemBuilder: (context, i) {
            final d = docs[i].data();
            return _MessageTile(
              username: d['username'] as String? ?? 'Roaster',
              text: d['text'] as String? ?? '',
              uid: d['uid'] as String? ?? '',
              isMine: d['uid'] == myUid,
            );
          },
        );
      },
    );
  }
}

class _MessageTile extends StatelessWidget {
  const _MessageTile({
    required this.username,
    required this.text,
    required this.uid,
    required this.isMine,
  });

  final String username;
  final String text;
  final String uid;
  final bool isMine;

  void _reportSheet(BuildContext context) {
    if (isMine || uid.isEmpty) return;
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: const Icon(Icons.flag_outlined),
              title: Text('Report $username'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => ReportScreen(reportedUserId: uid),
                ));
              },
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Align(
      alignment: isMine ? Alignment.centerRight : Alignment.centerLeft,
      child: GestureDetector(
        onLongPress: () => _reportSheet(context),
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 3),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          constraints:
              BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.78),
          decoration: BoxDecoration(
            color: isMine
                ? scheme.primary.withValues(alpha: 0.22)
                : scheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Column(
            crossAxisAlignment:
                isMine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
            children: [
              if (!isMine)
                Text(username,
                    style: textTheme.labelSmall?.copyWith(
                        color: scheme.primary, fontWeight: FontWeight.w700)),
              Text(text, style: textTheme.bodyMedium),
            ],
          ),
        ),
      ),
    );
  }
}

class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.sending,
    required this.onSend,
  });

  final TextEditingController controller;
  final bool sending;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 8),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: controller,
                minLines: 1,
                maxLines: 4,
                maxLength: 280,
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => onSend(),
                decoration: const InputDecoration(
                  hintText: 'Say something to the room…',
                  counterText: '',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filled(
              onPressed: sending ? null : onSend,
              icon: sending
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.send),
            ),
          ],
        ),
      ),
    );
  }
}
