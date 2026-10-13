import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../../core/services/hub_service.dart';
import '../../screens/moderation/report_screen.dart';
import '../../theme/app_theme.dart';
import '../admin_only.dart';

/// The Main Stage HUB weekly lobby chat.
///
/// A live, group, moderated, rate-limited, reportable room - the same
/// welfare-bounded chat as the gauntlet lobby (see lobby.js), keyed by the
/// qualifying [weekKey] so it's a fresh "this week's" green room every week.
/// Clients read it directly; every write goes through HubService (the
/// postHubMessage callable), so moderation can't be skipped. Founders can pin
/// an announcement (the 📣 button, admin-only).
class HubChat extends StatefulWidget {
  const HubChat({super.key, required this.weekKey});

  final String weekKey;

  @override
  State<HubChat> createState() => _HubChatState();
}

class _HubChatState extends State<HubChat> {
  final _controller = TextEditingController();
  bool _sending = false;

  CollectionReference<Map<String, dynamic>> get _messages =>
      FirebaseFirestore.instance
          .collection('lobbyRooms')
          .doc(widget.weekKey)
          .collection('messages');

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
      await HubService.postMessage(text);
      _controller.clear();
    } on FirebaseFunctionsException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.message ?? 'Could not post.')),
        );
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _postAnnouncement() async {
    final controller = TextEditingController();
    final text = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Pin an announcement'),
        content: TextField(
          controller: controller,
          maxLength: 280,
          maxLines: 3,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'Shown pinned above the chat for everyone.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
            child: const Text('Pin it'),
          ),
        ],
      ),
    );
    if (text == null || text.isEmpty) return;
    try {
      await HubService.postAnnouncement(text);
    } on FirebaseFunctionsException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.message ?? 'Could not post.')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final myUid = FirebaseAuth.instance.currentUser?.uid;
    return Column(
      children: [
        _Announcements(messages: _messages),
        Expanded(child: _ChatList(messages: _messages, myUid: myUid)),
        _Composer(
          controller: _controller,
          sending: _sending,
          onSend: _send,
          onAnnounce: _postAnnouncement,
        ),
      ],
    );
  }
}

/// Pinned founder announcements, shown above the chat. Renders nothing when
/// there are none. Uses a single-field `pinned == true` query (no composite
/// index) and sorts newest-first client-side.
class _Announcements extends StatelessWidget {
  const _Announcements({required this.messages});

  final CollectionReference<Map<String, dynamic>> messages;

  @override
  Widget build(BuildContext context) {
    final gold = context.palette.reward;
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: messages.where('pinned', isEqualTo: true).snapshots(),
      builder: (context, snap) {
        final docs = snap.data?.docs ?? const [];
        if (docs.isEmpty) return const SizedBox.shrink();
        final sorted = [...docs]..sort((a, b) {
            final ta = a.data()['createdAt'];
            final tb = b.data()['createdAt'];
            if (ta is Timestamp && tb is Timestamp) return tb.compareTo(ta);
            return 0;
          });
        return Column(
          children: sorted.take(3).map((d) {
            final text = d.data()['text'] as String? ?? '';
            return Container(
              margin: const EdgeInsets.fromLTRB(10, 8, 10, 0),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                color: gold.withValues(alpha: 0.12),
                border: Border.all(color: gold.withValues(alpha: 0.5)),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.campaign, size: 18, color: gold),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      text,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.95),
                        fontWeight: FontWeight.w600,
                        height: 1.3,
                      ),
                    ),
                  ),
                ],
              ),
            );
          }).toList(),
        );
      },
    );
  }
}

class _ChatList extends StatelessWidget {
  const _ChatList({required this.messages, required this.myUid});

  final CollectionReference<Map<String, dynamic>> messages;
  final String? myUid;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: messages.orderBy('createdAt', descending: true).limit(100).snapshots(),
      builder: (context, snap) {
        if (snap.hasError) {
          return const Center(child: Text('Could not load the chat.'));
        }
        if (!snap.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        // Announcements show in the pinned header above, not inline.
        final docs = snap.data!.docs
            .where((d) => d.data()['pinned'] != true)
            .toList();
        return ListView.builder(
          reverse: true,
          padding: const EdgeInsets.symmetric(vertical: 8),
          // +1 for the default room intro, always shown as the oldest message.
          itemCount: docs.length + 1,
          itemBuilder: (context, i) {
            if (i == docs.length) {
              return const _RoomIntro(
                text: 'This is the Main Stage chat room — keep it relevant, '
                    'and keep it comedy.',
              );
            }
            final d = docs[i].data();
            final uid = d['uid'] as String? ?? '';
            final name = d['username'] as String? ?? 'Roaster';
            final text = d['text'] as String? ?? '';
            final isMine = uid == myUid;
            return _MessageTile(
              name: name,
              text: text,
              isMine: isMine,
              onReport: isMine || uid.isEmpty
                  ? null
                  : () => Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => ReportScreen(reportedUserId: uid))),
            );
          },
        );
      },
    );
  }
}

class _MessageTile extends StatelessWidget {
  const _MessageTile({
    required this.name,
    required this.text,
    required this.isMine,
    this.onReport,
  });

  final String name;
  final String text;
  final bool isMine;
  final VoidCallback? onReport;

  @override
  Widget build(BuildContext context) {
    final accent = context.palette.reward;
    // One compact line per message - "Name: message" (Twitch-style), so chat
    // packs in without the old two-line name-over-bubble layout.
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
      child: GestureDetector(
        onLongPress: onReport,
        behavior: HitTestBehavior.opaque,
        child: Text.rich(
          TextSpan(children: [
            TextSpan(
              text: '${isMine ? 'You' : name}: ',
              style: TextStyle(
                color: isMine ? accent : Colors.white.withValues(alpha: 0.72),
                fontWeight: FontWeight.w800,
              ),
            ),
            TextSpan(
              text: text,
              style: const TextStyle(color: Colors.white),
            ),
          ]),
          style: const TextStyle(fontSize: 14, height: 1.3),
        ),
      ),
    );
  }
}

/// The default, always-present first line in a chat room - a quiet system note
/// that names the room and sets the tone. Rendered as the oldest message.
class _RoomIntro extends StatelessWidget {
  const _RoomIntro({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: TextStyle(
          color: Colors.white.withValues(alpha: 0.5),
          fontSize: 12,
          fontStyle: FontStyle.italic,
          height: 1.3,
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
    required this.onAnnounce,
  });

  final TextEditingController controller;
  final bool sending;
  final VoidCallback onSend;
  final VoidCallback onAnnounce;

  @override
  Widget build(BuildContext context) {
    final accent = context.palette.reward;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
        child: Row(
          children: [
            // Admin-only: pin an announcement to the room.
            AdminOnly(
              child: IconButton(
                icon: Icon(Icons.campaign, color: accent),
                tooltip: 'Pin an announcement',
                onPressed: onAnnounce,
              ),
            ),
            Expanded(
              child: TextField(
                controller: controller,
                maxLength: 280,
                minLines: 1,
                maxLines: 4,
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => onSend(),
                decoration: const InputDecoration(
                  hintText: 'Message the room…',
                  counterText: '',
                  border: OutlineInputBorder(),
                  contentPadding:
                      EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                ),
              ),
            ),
            const SizedBox(width: 6),
            IconButton(
              icon: sending
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Icon(Icons.send, color: accent),
              onPressed: sending ? null : onSend,
            ),
          ],
        ),
      ),
    );
  }
}
