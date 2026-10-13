import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../core/services/watch_feed_service.dart';
import '../theme/app_theme.dart';
import 'emoji_rate_row.dart';
import 'turnstile_challenge.dart';

/// The live crowd's reaction to a Main Stage battle.
///
/// The Main Stage WINNER is decided by the judge panel, not the crowd - so
/// this is NOT a ballot. What the crowd does while watching: rate each roaster
/// with one emoji (which feeds that roaster's permanent public emoji identity,
/// exactly like a judge's rating) and pick a non-binding Crowd Favourite.
///
/// One reaction per account per battle (the server enforces it). The rating is
/// changeable HERE, before you submit; after you submit it is locked and the
/// Crowd Favourite tally is revealed - hidden until then so the running
/// favourite can't bias your pick, the same rule the winner tally follows.
class LiveReactionPanel extends StatefulWidget {
  const LiveReactionPanel({
    super.key,
    required this.matchId,
    required this.player1Id,
    required this.player2Id,
    required this.player1Name,
    required this.player2Name,
  });

  final String matchId;
  final String player1Id;
  final String player2Id;
  final String player1Name;
  final String player2Name;

  @override
  State<LiveReactionPanel> createState() => _LiveReactionPanelState();
}

class _LiveReactionPanelState extends State<LiveReactionPanel> {
  final _feedService = WatchFeedService();

  String? _emojiP1;
  String? _emojiP2;
  String? _favorite;
  bool _busy = false;
  bool _reacted = false;
  bool _checking = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _checkReacted();
  }

  /// Have I already reacted? My reactor doc existing is the signal (and the
  /// only thing I'm allowed to read before reacting). A failure just leaves the
  /// picker up - the server refuses a second reaction anyway.
  Future<void> _checkReacted() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      if (mounted) setState(() => _checking = false);
      return;
    }
    try {
      final snap = await FirebaseFirestore.instance
          .collection('liveReactions')
          .doc(widget.matchId)
          .collection('reactors')
          .doc(uid)
          .get();
      if (!mounted) return;
      setState(() {
        _reacted = snap.exists;
        _checking = false;
      });
    } catch (_) {
      if (mounted) setState(() => _checking = false);
    }
  }

  /// One Turnstile solve covers a run (the same session voting uses), so a
  /// spectator reacting to a few battles solves at most once. Returns false if
  /// the check was dismissed.
  Future<bool> _ensureSession() async {
    try {
      if (await _feedService.sessionVotesRemaining() > 0) return true;
    } catch (_) {/* fall through to the challenge */}
    if (!mounted) return false;
    final token = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => Padding(
        padding:
            EdgeInsets.only(bottom: MediaQuery.of(sheetContext).viewInsets.bottom),
        child: Container(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Quick check before you react',
                  style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              const Text('Once only - then react to as many battles as you like.',
                  textAlign: TextAlign.center, style: TextStyle(fontSize: 12)),
              const SizedBox(height: 16),
              TurnstileChallenge(
                onToken: (t) => Navigator.of(sheetContext).pop(t),
              ),
            ],
          ),
        ),
      ),
    );
    if (token == null) return false;
    await _feedService.startSession(token);
    return true;
  }

  bool get _ready => _emojiP1 != null && _emojiP2 != null && _favorite != null;

  Future<void> _submit() async {
    if (!_ready || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final hasSession = await _ensureSession();
      if (!hasSession) {
        if (mounted) setState(() => _busy = false);
        return;
      }
      await FirebaseFunctions.instance
          .httpsCallable('castLiveReaction')
          .call<Map<String, dynamic>>({
        'matchId': widget.matchId,
        'emojiRatings': {
          widget.player1Id: _emojiP1,
          widget.player2Id: _emojiP2,
        },
        'favorite': _favorite,
      });
      if (mounted) {
        setState(() {
          _busy = false;
          _reacted = true;
        });
      }
    } on FirebaseFunctionsException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e.code == 'already-exists'
            ? 'You already reacted to this battle.'
            : e.message ?? 'Could not send that reaction.';
        if (e.code == 'already-exists') _reacted = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection('matches')
          .doc(widget.matchId)
          .snapshots(),
      builder: (context, snapshot) {
        final match = snapshot.data?.data();
        final closed = match != null && match['voteFinalized'] == true;
        if (_checking) return const SizedBox.shrink();
        if (_reacted) return _tally(context, closed);
        if (closed) {
          return _shell(context, [
            Text('Reactions closed.',
                style: Theme.of(context).textTheme.titleSmall),
          ]);
        }
        return _picker(context);
      },
    );
  }

  Widget _shell(BuildContext context, List<Widget> children) {
    return Container(
      width: double.infinity,
      color: Theme.of(context).colorScheme.surface,
      padding: const EdgeInsets.all(16),
      child: Column(mainAxisSize: MainAxisSize.min, children: children),
    );
  }

  Widget _picker(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return _shell(context, [
      Text('React to the roasters', style: text.titleMedium),
      const SizedBox(height: 2),
      Text('The judges pick the winner - this is your crowd reaction.',
          style: text.bodySmall),
      const SizedBox(height: 12),
      EmojiRateRow(
        name: widget.player1Name,
        selected: _emojiP1,
        dark: false,
        onSelect: (k) => setState(() => _emojiP1 = k),
      ),
      const SizedBox(height: 8),
      EmojiRateRow(
        name: widget.player2Name,
        selected: _emojiP2,
        dark: false,
        onSelect: (k) => setState(() => _emojiP2 = k),
      ),
      const SizedBox(height: 14),
      Text('Your crowd favourite:', style: text.bodySmall),
      const SizedBox(height: 8),
      Row(children: [
        Expanded(child: _favChoice(widget.player1Id, widget.player1Name)),
        const SizedBox(width: 8),
        Expanded(child: _favChoice(widget.player2Id, widget.player2Name)),
      ]),
      const SizedBox(height: 14),
      SizedBox(
        width: double.infinity,
        child: FilledButton(
          onPressed: (!_ready || _busy) ? null : _submit,
          child: _busy
              ? const SizedBox(
                  height: 18,
                  width: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(_emojiP1 == null || _emojiP2 == null
                  ? 'Rate both roasters'
                  : _favorite == null
                      ? 'Pick your favourite'
                      : 'Send reaction'),
        ),
      ),
      if (_error != null) ...[
        const SizedBox(height: 10),
        Text(_error!,
            textAlign: TextAlign.center,
            style: text.bodySmall
                ?.copyWith(color: Theme.of(context).colorScheme.error)),
      ],
    ]);
  }

  Widget _favChoice(String id, String name) {
    final scheme = Theme.of(context).colorScheme;
    final reward = context.palette.reward;
    final sel = _favorite == id;
    return OutlinedButton.icon(
      onPressed: _busy ? null : () => setState(() => _favorite = id),
      icon: Icon(sel ? Icons.star : Icons.star_border,
          size: 18, color: sel ? reward : scheme.outline),
      label: Text(name,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
              color: scheme.onSurface,
              fontWeight: sel ? FontWeight.bold : FontWeight.normal)),
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 11),
        backgroundColor: sel ? reward.withValues(alpha: 0.15) : null,
        side: BorderSide(
            color: sel ? reward : scheme.outlineVariant, width: sel ? 2 : 1),
      ),
    );
  }

  /// After reacting, the running Crowd Favourite - now that revealing it can no
  /// longer bias the pick. Reads liveReactions/{matchId}, which the rules let
  /// only a reactor read.
  Widget _tally(BuildContext context, bool closed) {
    final text = Theme.of(context).textTheme;
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection('liveReactions')
          .doc(widget.matchId)
          .snapshots(),
      builder: (context, snapshot) {
        final data = snapshot.data?.data();
        final favs = (data?['favorites'] as Map?) ?? const {};
        final n1 = (favs[widget.player1Id] as num?)?.toInt() ?? 0;
        final n2 = (favs[widget.player2Id] as num?)?.toInt() ?? 0;
        final leaderName = n1 == n2
            ? null
            : (n1 > n2 ? widget.player1Name : widget.player2Name);
        return _shell(context, [
          Text(closed ? 'Reaction in. Judges are deciding.' : 'Reaction in.',
              style: text.titleSmall),
          const SizedBox(height: 10),
          Row(children: [
            Expanded(child: _favBar(widget.player1Name, n1, n1 + n2)),
            const SizedBox(width: 10),
            Expanded(child: _favBar(widget.player2Name, n2, n1 + n2)),
          ]),
          const SizedBox(height: 10),
          Text(
            leaderName == null
                ? 'Crowd favourite: tied'
                : 'Crowd favourite: $leaderName',
            style: text.labelLarge
                ?.copyWith(color: context.palette.reward, fontWeight: FontWeight.w800),
          ),
        ]);
      },
    );
  }

  Widget _favBar(String name, int n, int total) {
    final reward = context.palette.reward;
    final frac = total == 0 ? 0.0 : n / total;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('$name  ($n)',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 4),
        ClipRRect(
          borderRadius: BorderRadius.circular(999),
          child: LinearProgressIndicator(
            value: frac,
            minHeight: 8,
            backgroundColor: reward.withValues(alpha: 0.12),
            valueColor: AlwaysStoppedAnimation(reward),
          ),
        ),
      ],
    );
  }
}
