import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../../widgets/home_action_button.dart';

import '../../core/services/matchmaking_service.dart';
import '../../theme/app_theme.dart';
import '../../widgets/looping_video.dart';
import '../match/pre_match_screen.dart';
import '../match/recording_consent_screen.dart';
import 'live_viewer_screen.dart';

/// The Daily Gauntlet's SWISS "most wins" format, from the player's seat.
///
/// Two phases:
///  - BEFORE 6pm (async study): sign up any time during the day, then study
///    "Tonight's Field" - every entrant's intro + ammo, with the people near
///    your rank quietly flagged. Signing up early buys more study time.
///  - IN THE WINDOW (live): poll `gauntletPoll` to be paired against the
///    nearest-record opponent you haven't faced; win/lose, keep playing; the
///    most wins at 7pm takes it. Nobody is eliminated.
class GauntletScreen extends StatefulWidget {
  const GauntletScreen({
    super.key,
    required this.tournamentId,
    this.name,
    this.consented = false,
  });

  final String tournamentId;
  final String? name;
  final bool consented;

  @override
  State<GauntletScreen> createState() => _GauntletScreenState();
}

class _GauntletScreenState extends State<GauntletScreen> {
  Timer? _poll;
  bool _signedUp = false;
  bool _signingUp = false;
  String? _signupError;
  String _pollState = "waiting"; // waiting | not_started | ended | done_playing | done
  Map<String, dynamic>? _standing;
  String? _championUid;
  String? _championName;
  String? _routedMatchId;
  bool _navigating = false;
  late bool _consented = widget.consented;

  static const _gold = Color(0xFFFFC107);

  String get _uid => FirebaseAuth.instance.currentUser!.uid;
  DocumentReference<Map<String, dynamic>> get _tRef =>
      FirebaseFirestore.instance.collection('tournaments').doc(widget.tournamentId);

  @override
  void initState() {
    super.initState();
    _checkSignedUp();
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _checkSignedUp() async {
    try {
      final snap = await _tRef.get();
      final entrants = _entrantsOf(snap.data());
      final mine = entrants.any((e) => e['uid'] == _uid);
      if (!mounted) return;
      setState(() => _signedUp = mine);
      if (mine) _startPolling();
    } catch (_) {/* the stream below still renders the field */}
  }

  Future<void> _signUp() async {
    setState(() {
      _signingUp = true;
      _signupError = null;
    });
    try {
      await FirebaseFunctions.instance
          .httpsCallable('signUpGauntlet')
          .call<Map<String, dynamic>>({'tournamentId': widget.tournamentId});
      if (!mounted) return;
      setState(() {
        _signedUp = true;
        _signingUp = false;
      });
      _startPolling();
    } on FirebaseFunctionsException catch (e) {
      if (!mounted) return;
      setState(() {
        _signingUp = false;
        _signupError = e.message ?? 'Could not sign up.';
      });
    }
  }

  void _startPolling() {
    _poll?.cancel();
    _poll = Timer.periodic(const Duration(seconds: 4), (_) => _pollOnce());
    _pollOnce();
  }

  Future<void> _pollOnce() async {
    if (_navigating || !_signedUp) return;
    try {
      final r = await FirebaseFunctions.instance
          .httpsCallable('gauntletPoll')
          .call<Map<String, dynamic>>({'tournamentId': widget.tournamentId});
      if (!mounted) return;
      final data = r.data;
      final state = data['state'] as String? ?? 'waiting';
      final standing = (data['standing'] as Map?)?.cast<String, dynamic>();

      if (state == 'in_match') {
        final matchId = data['matchId'] as String?;
        if (matchId != null && matchId != _routedMatchId) {
          _routedMatchId = matchId;
          await _goToMatch(MatchPairing.fromMap(
              data.cast<String, dynamic>(), fallbackMode: 'tournament'));
        }
        return;
      }
      if (state == 'done') {
        _poll?.cancel();
        _resolveChampion(data['winnerUid'] as String?);
        return;
      }
      setState(() {
        _pollState = state;
        _standing = standing ?? _standing;
      });
    } catch (_) {/* a dropped poll is harmless; next tick retries */}
  }

  Future<void> _goToMatch(MatchPairing pairing) async {
    _navigating = true;
    _poll?.cancel();
    if (!_consented) {
      final consented = await Navigator.of(context).push<bool>(
        MaterialPageRoute(builder: (_) => const RecordingConsentScreen()),
      );
      if (consented == true) _consented = true;
    }
    if (_consented && mounted) {
      await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => PreMatchScreen(mode: 'tournament', climbPairing: pairing),
      ));
    }
    _navigating = false;
    if (mounted) {
      // Do NOT reset _routedMatchId here. PreMatchScreen hands off to the bio
      // reveal via pushReplacement, which completes THIS push's future while
      // the player is still on the bio reveal - so polling resumes underneath.
      // Keeping the routed id means a poll that still reports the SAME pending
      // match is skipped (matchId == _routedMatchId) rather than re-pushing the
      // pre-match check on top of the battle. Only a NEW match (next round, a
      // fresh id) routes. Resetting it caused an infinite pre-match loop -
      // found on the 2026-09-16 two-phone dry run.
      _startPolling();
    }
  }

  Future<void> _resolveChampion(String? winnerUid) async {
    String? name;
    if (winnerUid != null) {
      try {
        final s = await FirebaseFirestore.instance
            .collection('users').doc(winnerUid).get();
        name = s.data()?['username'] as String?;
      } catch (_) {/* generic message */}
    }
    if (!mounted) return;
    setState(() {
      _pollState = "done";
      _championUid = winnerUid;
      _championName = name;
    });
  }

  static List<Map<String, dynamic>> _entrantsOf(Map<String, dynamic>? t) {
    final swiss = t?['swiss'] as Map<String, dynamic>?;
    final list = (swiss?['entrants'] as List?) ?? const [];
    return list.whereType<Map>().map((e) => e.cast<String, dynamic>()).toList();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.name ?? 'Daily Gauntlet'),
        actions: const [HomeActionButton()],
      ),
      // The tournament doc drives the roster + timing live; the poll drives the
      // battle state on top of it.
      body: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
        stream: _tRef.snapshots(),
        builder: (context, snap) {
          final t = snap.data?.data();
          if (t == null) {
            return const Center(child: CircularProgressIndicator());
          }
          return _body(context, t);
        },
      ),
    );
  }

  Widget _body(BuildContext context, Map<String, dynamic> t) {
    final status = t['status'] as String?;
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final startMs = (t['windowStartMs'] as num?)?.toInt() ??
        (t['startsAtMs'] as num?)?.toInt();
    final endMs = (t['windowEndMs'] as num?)?.toInt();
    final windowLive = startMs != null && endMs != null &&
        nowMs >= startMs && nowMs < endMs;
    final entrants = _entrantsOf(t);

    if (status == 'completed' || status == 'cancelled' || _pollState == 'done') {
      return _championView(context, t);
    }
    if (!_signedUp) {
      return _signupView(context, t, entrants, startMs);
    }
    // Signed up. Before the window: study. In the window: battle.
    if (windowLive && _pollState != 'not_started') {
      return _liveView(context, entrants);
    }
    return _studyView(context, entrants, startMs, live: windowLive);
  }

  // --- Sign up -------------------------------------------------------------

  Widget _signupView(BuildContext context, Map<String, dynamic> t,
      List<Map<String, dynamic>> entrants, int? startMs) {
    final text = Theme.of(context).textTheme;
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Icon(Icons.emoji_events, size: 48, color: _gold),
        const SizedBox(height: 12),
        Text('Sign up for tonight',
            style: text.headlineSmall?.copyWith(fontWeight: FontWeight.w800)),
        const SizedBox(height: 8),
        Text(
          'Everyone battles through the night and the most wins takes it - no '
          'knockouts, so you keep playing. Sign up now to study the field all '
          'day before it starts${_atTime(startMs)}.',
          style: text.bodyMedium,
        ),
        const SizedBox(height: 20),
        if (_signupError != null) ...[
          Text(_signupError!, style: TextStyle(color: context.palette.live)),
          const SizedBox(height: 12),
        ],
        FilledButton(
          onPressed: _signingUp ? null : _signUp,
          style: FilledButton.styleFrom(
            backgroundColor: _gold,
            foregroundColor: const Color(0xFF3A2A00),
            minimumSize: const Size(0, 52),
          ),
          child: _signingUp
              ? const SizedBox(
                  height: 20, width: 20,
                  child: CircularProgressIndicator(
                      strokeWidth: 2.5, color: Color(0xFF3A2A00)))
              : Text('${entrants.isEmpty ? 'Be the first in' : 'Join'} the field'),
        ),
        const SizedBox(height: 28),
        if (entrants.isNotEmpty)
          Text('${entrants.length} in the field so far',
              style: text.titleSmall?.copyWith(color: text.bodySmall?.color)),
      ],
    );
  }

  // --- Study phase (Tonight's Field) ---------------------------------------

  Widget _studyView(BuildContext context, List<Map<String, dynamic>> entrants,
      int? startMs, {required bool live}) {
    final text = Theme.of(context).textTheme;
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
      children: [
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: _gold.withValues(alpha: 0.5)),
            color: _gold.withValues(alpha: 0.06),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text("You're in tonight's field",
                  style: text.titleMedium?.copyWith(
                      fontWeight: FontWeight.w800, color: _gold)),
              const SizedBox(height: 4),
              Text(
                live
                    ? 'It has started - head in when you are ready.'
                    : 'Battling starts${_atTime(startMs)}. Study the field '
                        'below until then - the more you know, the better your '
                        'jokes.',
                style: text.bodyMedium,
              ),
            ],
          ),
        ),
        const SizedBox(height: 22),
        Text("Tonight's Field",
            style: text.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: 2),
        Text('Tap anyone to watch their intro and read their ammo.',
            style: text.bodySmall),
        const SizedBox(height: 12),
        _TonightsField(entrants: entrants, myUid: _uid),
      ],
    );
  }

  // --- Live battling -------------------------------------------------------

  Widget _liveView(BuildContext context, List<Map<String, dynamic>> entrants) {
    final text = Theme.of(context).textTheme;
    final wins = (_standing?['wins'] as num?)?.toInt() ?? 0;
    final losses = (_standing?['losses'] as num?)?.toInt() ?? 0;
    final rank = (_standing?['rank'] as num?)?.toInt();
    final count = (_standing?['playerCount'] as num?)?.toInt() ?? entrants.length;
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('$wins-$losses',
                  style: text.headlineMedium?.copyWith(
                      fontWeight: FontWeight.w900, color: _gold)),
              Text('wins - losses',
                  style: text.bodySmall?.copyWith(letterSpacing: 1)),
              const SizedBox(height: 8),
              Text(
                rank != null
                    ? 'Rank $rank of $count. Finding your next opponent...'
                    : 'Finding your next opponent...',
                style: text.bodyMedium,
              ),
              const SizedBox(height: 2),
              Text('Most wins at the end takes it. No knockouts - keep playing.',
                  style: text.bodySmall),
            ],
          ),
        ),
        const SizedBox(height: 22),
        Text('Live now - watch and vote', style: text.titleMedium),
        const SizedBox(height: 4),
        Text('Judging earns you points while you wait for your next match.',
            style: text.bodySmall),
        const SizedBox(height: 12),
        _WatchList(tournamentId: widget.tournamentId, myUid: _uid),
      ],
    );
  }

  // --- Champion ------------------------------------------------------------

  Widget _championView(BuildContext context, Map<String, dynamic> t) {
    final text = Theme.of(context).textTheme;
    final winnerUid = _championUid ?? t['winnerId'] as String?;
    final iWon = winnerUid != null && winnerUid == _uid;
    if (winnerUid == null) {
      return _centered(Icons.info_outline, 'No champion tonight',
          'Not enough battles happened to crown one. Back tomorrow.');
    }
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.emoji_events, size: 56, color: _gold),
            const SizedBox(height: 16),
            Text(iWon ? 'You won the whole thing.' : 'We have a champion',
                style: text.headlineSmall?.copyWith(fontWeight: FontWeight.bold),
                textAlign: TextAlign.center),
            const SizedBox(height: 8),
            Text(
              iWon
                  ? 'Most wins tonight. Enjoy it.'
                  : _championName != null
                      ? '$_championName had the most wins tonight.'
                      : "Tonight's gauntlet is decided.",
              style: text.bodyMedium, textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }

  Widget _centered(IconData icon, String title, String body) {
    final text = Theme.of(context).textTheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 44,
                color: Theme.of(context).colorScheme.onSurfaceVariant),
            const SizedBox(height: 14),
            Text(title,
                style: text.headlineSmall?.copyWith(fontWeight: FontWeight.bold),
                textAlign: TextAlign.center),
            const SizedBox(height: 8),
            Text(body, style: text.bodyMedium, textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }

  String _atTime(int? startMs) {
    if (startMs == null) return '';
    final dt = DateTime.fromMillisecondsSinceEpoch(startMs).toLocal();
    final h = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
    final ampm = dt.hour < 12 ? 'am' : 'pm';
    final m = dt.minute == 0 ? '' : ':${dt.minute.toString().padLeft(2, '0')}';
    return ' at $h$m$ampm';
  }
}

/// The roster people study during the day: every entrant, with the people near
/// your rank quietly flagged. Fetches each entrant's public profile once.
class _TonightsField extends StatefulWidget {
  const _TonightsField({required this.entrants, required this.myUid});

  final List<Map<String, dynamic>> entrants;
  final String myUid;

  @override
  State<_TonightsField> createState() => _TonightsFieldState();
}

class _TonightsFieldState extends State<_TonightsField> {
  Map<String, Map<String, dynamic>> _profiles = {};
  String? _myRank;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant _TonightsField old) {
    super.didUpdateWidget(old);
    // Refetch only when someone new joined the field.
    if (widget.entrants.length != old.entrants.length) _load();
  }

  Future<void> _load() async {
    try {
      final db = FirebaseFirestore.instance;
      final uids = widget.entrants.map((e) => e['uid'] as String).toList();
      final docs = await Future.wait(
          uids.map((u) => db.collection('users').doc(u).get()));
      final map = <String, Map<String, dynamic>>{};
      for (final d in docs) {
        if (d.exists) map[d.id] = d.data()!;
      }
      if (!mounted) return;
      setState(() {
        _profiles = map;
        _myRank = map[widget.myUid]?['rankTitle'] as String?;
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    // Others only (you don't study yourself); near-rank first, then the rest.
    final others = widget.entrants
        .where((e) => e['uid'] != widget.myUid)
        .toList();
    if (others.isEmpty) {
      return Text('Nobody else yet. Check back as the field fills up.',
          style: Theme.of(context).textTheme.bodySmall);
    }
    bool near(Map<String, dynamic> e) {
      final r = _profiles[e['uid']]?['rankTitle'] as String?;
      return _myRank != null && r != null && r == _myRank;
    }
    others.sort((a, b) {
      final na = near(a), nb = near(b);
      if (na != nb) return na ? -1 : 1;
      return 0;
    });
    return Column(
      children: [
        for (final e in others)
          _EntrantCard(
            uid: e['uid'] as String,
            profile: _profiles[e['uid']],
            nearRank: near(e),
          ),
      ],
    );
  }
}

class _EntrantCard extends StatelessWidget {
  const _EntrantCard({required this.uid, required this.profile, required this.nearRank});

  final String uid;
  final Map<String, dynamic>? profile;
  final bool nearRank;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final name = profile?['username'] as String? ?? 'Roaster';
    final rank = profile?['rankTitle'] as String?;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
          child: const Icon(Icons.person, size: 20),
        ),
        title: Text(name, style: text.titleSmall),
        subtitle: rank != null ? Text(rank) : null,
        trailing: nearRank
            // Plain, direct - not a hyped "study these first!" cue.
            ? Chip(
                label: const Text('Near your rank'),
                visualDensity: VisualDensity.compact,
                labelStyle: text.labelSmall,
                side: BorderSide(color: Colors.white.withValues(alpha: 0.15)),
              )
            : const Icon(Icons.chevron_right),
        onTap: () => showModalBottomSheet<void>(
          context: context,
          isScrollControlled: true,
          showDragHandle: true,
          builder: (_) => _StudySheet(name: name, rank: rank, profile: profile),
        ),
      ),
    );
  }
}

/// The study sheet: an entrant's intro video and ammo - the material you use to
/// write jokes about them. Public study fields only.
class _StudySheet extends StatelessWidget {
  const _StudySheet({required this.name, required this.rank, required this.profile});

  final String name;
  final String? rank;
  final Map<String, dynamic>? profile;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final prof = profile?['profile'] as Map<String, dynamic>?;
    final intro = prof?['introVideoUrl'] as String?;
    final ammo = prof?['ammoText'] as String?;
    return SafeArea(
      top: false,
      child: Padding(
        padding: EdgeInsets.fromLTRB(
            20, 4, 20, 20 + MediaQuery.of(context).padding.bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(name,
                style: text.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
            if (rank != null)
              Text(rank!, style: text.bodySmall),
            const SizedBox(height: 14),
            if (intro != null && intro.isNotEmpty)
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: AspectRatio(
                  aspectRatio: 9 / 16,
                  child: LoopingVideo(url: intro, muted: false),
                ),
              )
            else
              Text('No intro video.', style: text.bodySmall),
            const SizedBox(height: 16),
            Text('AMMO',
                style: text.labelSmall?.copyWith(letterSpacing: 1.5)),
            const SizedBox(height: 6),
            Text(
              (ammo != null && ammo.trim().isNotEmpty)
                  ? ammo
                  : 'They left their ammo blank. You are on your own.',
              style: text.bodyMedium,
            ),
          ],
        ),
      ),
    );
  }
}

/// The live gauntlet battles happening right now, other than the viewer's own.
class _WatchList extends StatelessWidget {
  const _WatchList({required this.tournamentId, required this.myUid});

  final String tournamentId;
  final String myUid;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection('tournaments').doc(tournamentId).snapshots(),
      builder: (context, snapshot) {
        final entrants = ((snapshot.data?.data()?['swiss']
            as Map<String, dynamic>?)?['entrants'] as List?) ?? const [];
        final matchIds = <String>{};
        for (final e in entrants) {
          final m = (e as Map)['currentMatchId'] as String?;
          if (m == null || e['uid'] == myUid) continue;
          matchIds.add(m);
        }
        if (matchIds.isEmpty) {
          return Text('No other battles live this second - hang tight.',
              style: Theme.of(context).textTheme.bodySmall);
        }
        return Column(
          children: [
            for (final matchId in matchIds)
              Card(
                child: ListTile(
                  leading: Icon(Icons.sensors, color: context.palette.live),
                  title: const Text('Live battle'),
                  subtitle: const Text('Watch and vote'),
                  trailing: const Icon(Icons.play_arrow),
                  onTap: () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => LiveViewerScreen(matchId: matchId),
                  )),
                ),
              ),
          ],
        );
      },
    );
  }
}
