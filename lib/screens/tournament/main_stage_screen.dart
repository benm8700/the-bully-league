import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../../core/services/main_stage_service.dart';
import '../../theme/app_theme.dart';
import '../../widgets/empty_state.dart';
import '../match/pre_match_screen.dart';
import '../match/recording_consent_screen.dart';
import 'judges_room_screen.dart';
import 'live_viewer_screen.dart';
import 'main_stage_callout_screen.dart';
import 'main_stage_rules_screen.dart';

/// The Main Stage (weekly finals) front door: tells the viewer where they stand
/// after Wednesday's snapshot - finalist / alternate / judge / nobody - lets
/// finalists, alternates and judges accept or decline, and once the field locks
/// routes the #1 seed into their callout. Drives the already-deployed
/// respondToMainStageInvite / mainStageCallout callables. The live battle +
/// judges' room are separate screens (not built yet); this is the entry point.
class MainStageScreen extends StatefulWidget {
  const MainStageScreen({super.key, this.service});

  final MainStageService? service;

  @override
  State<MainStageScreen> createState() => _MainStageScreenState();
}

class _MainStageScreenState extends State<MainStageScreen> {
  late final MainStageService _service = widget.service ?? MainStageService();
  bool _submitting = false;
  bool _startingBattle = false;
  String? _error;

  /// A finals battle is recorded, so recording consent is required first (same
  /// as every recorded match); then a camera/mic check, which matters MORE
  /// here than in ranked - a finals battle can't be requeued if the setup is
  /// bad. The check CREATES the battle only on "ready" (startBattle lives in
  /// PreMatchScreen's mainStageStart branch), so a back-out strands nothing.
  Future<void> _startBattle(MainStageView v) async {
    if (v.myMatchupRound == null || v.myMatchupIndex == null) return;
    setState(() {
      _startingBattle = true;
      _error = null;
    });
    try {
      final consented = await Navigator.of(context).push<bool>(
        MaterialPageRoute(builder: (_) => const RecordingConsentScreen()),
      );
      if (consented != true) {
        if (mounted) setState(() => _startingBattle = false);
        return;
      }
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => PreMatchScreen(
            mode: 'ranked', // unused for the mainStage branch (no queue)
            mainStageStart: MainStageStart(
              tournamentId: v.tournamentId,
              roundIdx: v.myMatchupRound!,
              matchIdx: v.myMatchupIndex!,
            ),
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _startingBattle = false);
    }
  }

  Future<void> _respond(String tournamentId, bool accept) async {
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      await _service.respondToInvite(tournamentId, accept);
    } catch (e) {
      if (mounted) setState(() => _error = "Couldn't save that — try again.");
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Main Stage'),
        actions: [
          IconButton(
            icon: const Icon(Icons.help_outline),
            tooltip: 'How the Main Stage works',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const MainStageRulesScreen(),
              ),
            ),
          ),
        ],
      ),
      body: StreamBuilder<MainStageView?>(
        stream: _service.watch(),
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          final v = snap.data;
          if (v == null) {
            return const EmptyState(
              icon: Icons.emoji_events_outlined,
              title: 'No Main Stage running',
              message:
                  'The weekly finals get set after Wednesday night. Keep '
                  'battling ranked — the top of the leaderboard goes to the '
                  'Main Stage.',
            );
          }
          return ListView(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
            children: _body(v),
          );
        },
      ),
    );
  }

  List<Widget> _body(MainStageView v) {
    if (v.status == 'live') {
      final gold = context.palette.reward;
      if (v.hasBattleToPlay) {
        return [
          _headline("You're up on the Main Stage", context.palette.live),
          const SizedBox(height: 8),
          Text('Your semifinal is ready. Step on stage when you are.',
              style: _muted()),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!, style: TextStyle(color: context.palette.live)),
          ],
          const SizedBox(height: 20),
          FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: gold,
              foregroundColor: Colors.black,
              minimumSize: const Size(0, 54),
            ),
            icon: const Icon(Icons.mic),
            label: const Text('Play your match'),
            onPressed: _startingBattle ? null : () => _startBattle(v),
          ),
          const SizedBox(height: 8),
          Center(child: _rulesLink('New to this? How a Main Stage battle works')),
        ];
      }
      if (v.role == MainStageRole.judge) {
        final battle = v.liveBattleMatchId;
        return [
          _headline('The Main Stage is LIVE', context.palette.live),
          const SizedBox(height: 8),
          Text('You are on the panel. Watch the battle and cast your verdict.',
              style: _muted()),
          const SizedBox(height: 20),
          if (battle != null)
            FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: gold,
                foregroundColor: Colors.black,
                minimumSize: const Size(0, 54),
              ),
              icon: const Icon(Icons.gavel),
              label: const Text("Open the judges' room"),
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => JudgesRoomScreen(matchId: battle),
                ),
              ),
            )
          else
            _statusPill(Icons.hourglass_top, 'Between battles',
                'The next battle is being set up. The room opens when the '
                    'battlers step on stage.', gold),
        ];
      }
      // Finalist waiting their turn, or the crowd: watch the battle on stage.
      final battle = v.liveBattleMatchId;
      return [
        _headline('The Main Stage is LIVE', context.palette.live),
        const SizedBox(height: 8),
        Text(
            v.role == MainStageRole.finalist
                ? "You're in the bracket — watch the battle on stage while you "
                    'wait for your turn.'
                : 'The finals are happening now — watch the battles live.',
            style: _muted()),
        const SizedBox(height: 20),
        if (battle != null)
          FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: context.palette.live,
              foregroundColor: Colors.white,
              minimumSize: const Size(0, 54),
            ),
            icon: const Icon(Icons.visibility),
            label: const Text('Watch the battle'),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => LiveViewerScreen(matchId: battle),
              ),
            ),
          )
        else
          _statusPill(Icons.hourglass_top, 'Between battles',
              'The next battle is being set up — hang tight.',
              Theme.of(context).colorScheme.onSurfaceVariant),
      ];
    }
    // The announced field (with the wild-card reveal) shows below the viewer's
    // own status in both the locked and accepting states.
    if (v.status == 'locked') return [..._locked(v), _fieldWidget(v)];
    // accepting
    final base = switch (v.role) {
      MainStageRole.finalist => _invite(v, "You made the Main Stage.",
          "Top 4 this week. Confirm you're in by Thursday 4pm or your spot "
              'goes to an alternate.'),
      MainStageRole.alternate => _invite(v, "You're an alternate.",
          "Ranks 5-8 this week. If a finalist drops by Thursday 4pm, the "
              'highest confirmed alternate rolls in — so confirm you\'re '
              'around just in case.'),
      MainStageRole.judge => _invite(v, "You're on the judging panel.",
          'Five judges decide the finals live on stage. Confirm by Thursday '
              '4pm.'),
      MainStageRole.none => <Widget>[
          const EmptyState(
            icon: Icons.visibility_outlined,
            title: "You're not in this week's finals",
            message:
                'Watch the Main Stage live — the crowd is half the show. Climb '
                'the ladder this week for a shot next time.',
          ),
        ],
    };
    return [...base, _fieldWidget(v)];
  }

  /// The announced finals field with the wild card marked. Uses the locked
  /// field once it's set, else the snapshot finalists (known from Wednesday).
  Widget _fieldWidget(MainStageView v) {
    final uids = v.field.isNotEmpty ? v.field : v.finalists;
    if (uids.isEmpty) return const SizedBox.shrink();
    return _FieldRoster(uids: uids, wildCardUid: v.wildCardUid);
  }

  List<Widget> _invite(MainStageView v, String title, String blurb) {
    final gold = context.palette.reward;
    if (v.invite == InviteStatus.accepted) {
      return [
        _headline(title, gold),
        const SizedBox(height: 8),
        Text(blurb, style: _muted()),
        const SizedBox(height: 20),
        _statusPill(Icons.check_circle, "You're confirmed",
            'Field locks Thursday 4pm. See you on stage.', gold),
      ];
    }
    if (v.invite == InviteStatus.declined) {
      return [
        _headline(title, gold),
        const SizedBox(height: 20),
        _statusPill(Icons.cancel_outlined, 'You declined',
            'Changed your mind? Tap Accept before Thursday 4pm.',
            Theme.of(context).colorScheme.onSurfaceVariant),
        const SizedBox(height: 16),
        _acceptButton(v, gold, label: 'Actually, I\'m in'),
      ];
    }
    // pending (or somehow not invited but role matched — offer accept anyway)
    return [
      _headline(title, gold),
      const SizedBox(height: 8),
      Text(blurb, style: _muted()),
      if (_error != null) ...[
        const SizedBox(height: 12),
        Text(_error!, style: TextStyle(color: context.palette.live)),
      ],
      const SizedBox(height: 24),
      _acceptButton(v, gold),
      const SizedBox(height: 10),
      OutlinedButton(
        onPressed:
            _submitting ? null : () => _respond(v.tournamentId, false),
        style: OutlinedButton.styleFrom(minimumSize: const Size(0, 48)),
        child: const Text("Can't make it"),
      ),
    ];
  }

  Widget _acceptButton(MainStageView v, Color gold, {String label = "I'm in"}) {
    return FilledButton(
      style: FilledButton.styleFrom(
        backgroundColor: gold,
        foregroundColor: Colors.black,
        minimumSize: const Size(0, 52),
      ),
      onPressed: _submitting ? null : () => _respond(v.tournamentId, true),
      child: _submitting
          ? const SizedBox(
              height: 20,
              width: 20,
              child: CircularProgressIndicator(strokeWidth: 2))
          : Text(label),
    );
  }

  List<Widget> _locked(MainStageView v) {
    final gold = context.palette.reward;
    final widgets = <Widget>[
      _headline('The field is locked', gold),
      const SizedBox(height: 8),
      Text('Four finalists. Single elimination. One battle at a time.',
          style: _muted()),
      const SizedBox(height: 20),
    ];
    if (v.calloutOpen) {
      widgets.addAll([
        _statusPill(Icons.campaign, "You're the #1 seed",
            'You pick who you want in your semifinal. Make the call.', gold),
        const SizedBox(height: 16),
        FilledButton.icon(
          style: FilledButton.styleFrom(
            backgroundColor: gold,
            foregroundColor: Colors.black,
            minimumSize: const Size(0, 52),
          ),
          icon: const Icon(Icons.campaign),
          label: const Text('Make your callout'),
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => MainStageCalloutScreen(
                tournamentId: v.tournamentId,
                candidates: v.candidates,
              ),
            ),
          ),
        ),
      ]);
    } else if (v.role == MainStageRole.finalist) {
      widgets.add(_statusPill(Icons.hourglass_top, "You're in the bracket",
          'The #1 seed makes their callout on stage, then the battles begin.',
          gold));
      widgets.add(const SizedBox(height: 8));
      widgets.add(Center(
          child: _rulesLink('Know the rules before you step up')));
    } else if (v.role == MainStageRole.judge) {
      widgets.add(_statusPill(Icons.gavel, "You're judging",
          'Five of you decide the finals. The show starts at 6pm.', gold));
    } else {
      widgets.add(_statusPill(Icons.visibility, 'Field set',
          'Come watch the finals live at 6pm.',
          Theme.of(context).colorScheme.onSurfaceVariant));
    }
    return widgets;
  }

  Widget _rulesLink(String label) => TextButton.icon(
        onPressed: () => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => const MainStageRulesScreen(),
          ),
        ),
        icon: const Icon(Icons.help_outline, size: 18),
        label: Text(label),
      );

  Widget _headline(String s, Color color) => Text(
        s,
        style: Theme.of(context)
            .textTheme
            .headlineSmall
            ?.copyWith(fontWeight: FontWeight.w800, color: color),
      );

  TextStyle? _muted() => Theme.of(context)
      .textTheme
      .bodyMedium
      ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant);

  Widget _statusPill(IconData icon, String title, String sub, Color color) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: Theme.of(context)
                        .textTheme
                        .titleSmall
                        ?.copyWith(fontWeight: FontWeight.w700)),
                const SizedBox(height: 2),
                Text(sub, style: _muted()),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The announced finals field, with the seat-4 WILD CARD marked - the
/// "wild-card draw" reveal. Seeds 1..3 are the skill locks; the seat matching
/// [wildCardUid] is the player drawn in by engagement. Resolves usernames once.
class _FieldRoster extends StatefulWidget {
  const _FieldRoster({required this.uids, required this.wildCardUid});

  final List<String> uids;
  final String? wildCardUid;

  @override
  State<_FieldRoster> createState() => _FieldRosterState();
}

class _FieldRosterState extends State<_FieldRoster> {
  final Map<String, String> _names = {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final uids = widget.uids.toSet().take(10).toList();
      if (uids.isNotEmpty) {
        final q = await FirebaseFirestore.instance
            .collection('users')
            .where(FieldPath.documentId, whereIn: uids)
            .get();
        for (final d in q.docs) {
          final n = d.data()['username'];
          if (n is String) _names[d.id] = n;
        }
      }
    } catch (_) {
      // Names are a nicety; fall back to "Roaster".
    }
    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    final gold = context.palette.reward;
    final text = Theme.of(context).textTheme;
    final me = FirebaseAuth.instance.currentUser?.uid;
    final wc = widget.wildCardUid;
    final iAmWild = wc != null && wc == me;

    final reveal = iAmWild
        ? "\u{1F3B2} You drew the wild card — you're in the finals."
        : (wc != null
            ? 'Top 3 locked in by skill. The 4th is the wild-card draw.'
            : 'The finals field.');

    return Container(
      margin: const EdgeInsets.only(top: 22),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        color: Colors.black.withValues(alpha: 0.3),
        border: Border.all(color: gold.withValues(alpha: 0.45)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('THE FIELD',
              style: text.labelMedium?.copyWith(
                  color: gold, fontWeight: FontWeight.w900, letterSpacing: 1)),
          const SizedBox(height: 2),
          Text(reveal,
              style: text.bodySmall
                  ?.copyWith(color: Colors.white.withValues(alpha: 0.78))),
          const SizedBox(height: 10),
          ...List.generate(widget.uids.length, (i) {
            final uid = widget.uids[i];
            final isWild = wc != null && uid == wc;
            final isMe = uid == me;
            final name = _loading ? '…' : (_names[uid] ?? 'Roaster');
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 5),
              child: Row(
                children: [
                  SizedBox(
                    width: 30,
                    child: isWild
                        ? const Text('\u{1F3B2}',
                            style: TextStyle(fontSize: 17))
                        : Text('${i + 1}',
                            style: text.titleMedium?.copyWith(
                                color: gold, fontWeight: FontWeight.w900)),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      isMe ? '$name (you)' : name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          color: Colors.white,
                          fontWeight:
                              isMe ? FontWeight.w800 : FontWeight.w600),
                    ),
                  ),
                  if (isWild)
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(8),
                        color: gold.withValues(alpha: 0.18),
                        border: Border.all(color: gold.withValues(alpha: 0.6)),
                      ),
                      child: Text('WILD CARD',
                          style: TextStyle(
                              color: gold,
                              fontSize: 10,
                              fontWeight: FontWeight.w900,
                              letterSpacing: 0.5)),
                    ),
                ],
              ),
            );
          }),
        ],
      ),
    );
  }
}
