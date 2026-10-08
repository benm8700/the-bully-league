import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../../core/services/lobby_service.dart';
import '../../theme/app_theme.dart';
import '../../widgets/home_action_button.dart';
import '../../widgets/home/rank_badges.dart';
import '../moderation/report_screen.dart';
import '../profile/performer_profile_screen.dart';
import 'gauntlet_watch.dart';

/// The Daily Gauntlet LOBBY: a whole-event "green room".
///
/// Everyone in tonight's gauntlet (and anyone watching) gathers here between
/// battles - see who turned up, tap into their profile, and talk in one shared,
/// live chat. The chat is EPHEMERAL: it's wiped the moment the gauntlet ends
/// (server-side, onGauntletEnded), so a night's banter never outlives the
/// night. Every message is moderated + rate-limited server-side before it
/// appears, and any message can be reported (long-press) into the review queue.
class GauntletLobbyScreen extends StatefulWidget {
  const GauntletLobbyScreen({
    super.key,
    required this.tournamentId,
    this.name,
  });

  final String tournamentId;
  final String? name;

  @override
  State<GauntletLobbyScreen> createState() => _GauntletLobbyScreenState();
}

class _GauntletLobbyScreenState extends State<GauntletLobbyScreen> {
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
        // The server's message is the one that knows why (too fast, blocked,
        // gauntlet ended). Show it plainly.
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
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.name == null ? 'Lobby' : '${widget.name} · Lobby'),
        actions: const [HomeActionButton()],
      ),
      // A command centre for everyone waiting (the eliminated, the between-
      // battles, the spectators): the live status up top - time left, how many
      // battles are on, who's still in, who's out - and the chat below, open
      // throughout so people who've already gone can keep talking.
      body: Column(
        children: [
          _CommandHeader(
              tournamentId: widget.tournamentId, name: widget.name),
          _Roster(tournamentId: widget.tournamentId),
          const Divider(height: 1),
          Expanded(
            child: _ChatList(
              tournamentId: widget.tournamentId,
              myUid: _myUid,
            ),
          ),
          _Composer(
            controller: _controller,
            sending: _sending,
            onSend: _send,
          ),
        ],
      ),
    );
  }
}

/// The command-centre status strip: time left in the window, how many battles
/// are live, who's still in, who's knocked out, and a tap into the live
/// battles to watch. Ticks every 30s so the countdown stays current.
class _CommandHeader extends StatefulWidget {
  const _CommandHeader({required this.tournamentId, this.name});

  final String tournamentId;
  final String? name;

  @override
  State<_CommandHeader> createState() => _CommandHeaderState();
}

class _CommandHeaderState extends State<_CommandHeader> {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection('tournaments')
          .doc(widget.tournamentId)
          .snapshots(),
      builder: (context, snap) {
        final data = snap.data?.data();
        final climbers = ((data?['climb'] as Map<String, dynamic>?)?['climbers']
                as List?) ??
            const [];
        final s = GauntletState.fromClimbers(climbers);
        final endMs = (data?['windowEndMs'] as num?)?.toInt();
        final minsLeft = endMs == null
            ? null
            : ((endMs - DateTime.now().millisecondsSinceEpoch) / 60000).ceil();
        final showCountdown =
            minsLeft != null && minsLeft > 0 && minsLeft < 24 * 60;
        return Container(
          margin: const EdgeInsets.fromLTRB(12, 12, 12, 4),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.name ?? 'Daily Gauntlet',
                      style: Theme.of(context)
                          .textTheme
                          .titleSmall
                          ?.copyWith(fontWeight: FontWeight.w800),
                    ),
                  ),
                  if (showCountdown)
                    Row(mainAxisSize: MainAxisSize.min, children: [
                      Icon(Icons.timer_outlined,
                          size: 15, color: context.palette.live),
                      const SizedBox(width: 4),
                      Text('${minsLeft}m left',
                          style: Theme.of(context).textTheme.labelMedium?.copyWith(
                              color: context.palette.live,
                              fontWeight: FontWeight.w700)),
                    ]),
                ],
              ),
              const SizedBox(height: 10),
              Row(children: [
                _stat(context, s.liveMatches.length,
                    s.liveMatches.length == 1 ? 'battle on' : 'battles on',
                    context.palette.live),
                _stat(context, s.alive, 'still in', context.palette.reward),
                _stat(context, s.eliminated, 'knocked out',
                    scheme.onSurfaceVariant),
              ]),
              if (s.liveMatches.isNotEmpty)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => GauntletWatchScreen(
                          tournamentId: widget.tournamentId,
                          name: widget.name,
                        ),
                      ),
                    ),
                    icon: Icon(Icons.sensors,
                        size: 16, color: context.palette.live),
                    label: const Text('Watch the live battles'),
                    style: TextButton.styleFrom(
                      padding:
                          const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      minimumSize: const Size(0, 30),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _stat(BuildContext context, int value, String label, Color color) {
    return Expanded(
      child: Column(children: [
        Text('$value',
            style: Theme.of(context)
                .textTheme
                .titleLarge
                ?.copyWith(fontWeight: FontWeight.w800, color: color)),
        Text(label,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant),
            textAlign: TextAlign.center),
      ]),
    );
  }
}

/// "Who's in tonight" - a horizontal strip of the gauntlet's climbers. Tap a
/// card to open their profile. Read live off the tournament doc's climbers.
class _Roster extends StatelessWidget {
  const _Roster({required this.tournamentId});

  final String tournamentId;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection('tournaments')
          .doc(tournamentId)
          .snapshots(),
      builder: (context, snapshot) {
        final climbers = ((snapshot.data?.data()?['climb']
                as Map<String, dynamic>?)?['climbers'] as List?) ??
            const [];
        final uids = <String>[];
        for (final raw in climbers) {
          final uid = (raw as Map)['uid'] as String?;
          if (uid != null) uids.add(uid);
        }
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                uids.isEmpty
                    ? 'Nobody in the gauntlet yet'
                    : "Who's in tonight · ${uids.length}",
                style: Theme.of(context)
                    .textTheme
                    .labelLarge
                    ?.copyWith(fontWeight: FontWeight.w700),
              ),
              if (uids.isNotEmpty) ...[
                const SizedBox(height: 10),
                SizedBox(
                  height: 78,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: uids.length,
                    separatorBuilder: (_, _) => const SizedBox(width: 14),
                    itemBuilder: (_, i) => _RosterChip(uid: uids[i]),
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

class _RosterChip extends StatelessWidget {
  const _RosterChip({required this.uid});

  final String uid;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance.collection('users').doc(uid).snapshots(),
      builder: (context, snap) {
        final u = snap.data?.data();
        final username = u?['username'] as String? ?? 'Roaster';
        final rankTitle = u?['rankTitle'] as String?;
        return InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () =>
              PerformerProfileScreen.open(context, uid, username: username),
          child: SizedBox(
            width: 64,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (rankTitle != null)
                  RankBadge(title: rankTitle, size: 42)
                else
                  const Icon(Icons.person, size: 42),
                const SizedBox(height: 4),
                Text(
                  username,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// The live chat. Newest at the bottom (reversed list), each message
/// long-press -> report. Read directly (a cheap listener); posting goes
/// through the moderated callable.
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
              padding: const EdgeInsets.all(28),
              child: Text(
                'Quiet in here. Say something - the room is watching.\n'
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
    final text2 = Theme.of(context).textTheme;
    return Align(
      alignment: isMine ? Alignment.centerRight : Alignment.centerLeft,
      child: GestureDetector(
        onLongPress: () => _reportSheet(context),
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 3),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          constraints: BoxConstraints(
              maxWidth: MediaQuery.of(context).size.width * 0.78),
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
                Text(
                  username,
                  style: text2.labelSmall?.copyWith(
                      color: scheme.primary,
                      fontWeight: FontWeight.w700),
                ),
              Text(text, style: text2.bodyMedium),
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
