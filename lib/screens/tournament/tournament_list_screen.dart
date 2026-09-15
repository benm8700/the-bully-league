import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import '../../widgets/admin_only.dart';
import 'tournament_detail_screen.dart';

/// Which bucket of tournaments the segmented control is showing.
enum _TournamentFilter { active, upcoming, completed }

/// Browse tournaments (Build Order step 8) - VISUAL REDESIGN (2026-09-15).
///
/// This is a UI-only redesign to the cinematic "My Tournaments" reference:
/// a full-screen arena background (top-centred, fading to near-black behind
/// the UI), a bold non-serif "MY TOURNAMENTS" title with a pink outlined
/// JOIN button, an ACTIVE/UPCOMING/COMPLETED segmented control, and rich
/// but restrained tournament cards. NONE of the existing tournament logic,
/// models, state, navigation or backend changed: it still streams the
/// `tournaments` collection, buckets by the real `status`/`format`/timing
/// fields, derives roaster/stage/progress from `bracket.rounds` and
/// `climb.climbers`, and taps through to the unchanged
/// [TournamentDetailScreen] where join/check-in/the gauntlet already live.
///
/// Real tournament CREATION is still the admin-only debug path (the FAB),
/// per CLAUDE.md's "admin uses the Firebase console" pattern.
///
/// BACKGROUND ASSET NOTE: the developer's dedicated tournament background
/// PNG was not in the project when this was built, so it stands in the
/// existing arena hero art. Swap [_backgroundAsset] to the real file once
/// it is added under assets/home/ - one line, nothing else changes.
class TournamentListScreen extends StatefulWidget {
  const TournamentListScreen({super.key});

  @override
  State<TournamentListScreen> createState() => _TournamentListScreenState();
}

class _TournamentListScreenState extends State<TournamentListScreen> {
  /// The arena background: the tournament hero art cropped to its top
  /// crown/crowd/stage so the baked "TOURNAMENT" title isn't shown behind the
  /// "MY TOURNAMENTS" heading. Swap this for a purpose-made background PNG
  /// later if one is added under assets/home/.
  static const _backgroundAsset = 'assets/home/tournament_background.png';

  bool _creating = false;
  _TournamentFilter _filter = _TournamentFilter.active;

  Future<void> _createTestTournament() async {
    setState(() => _creating = true);
    try {
      final callable =
          FirebaseFunctions.instance.httpsCallable('debugCreateTournament');
      await callable.call({
        'name': 'Test Cup ${DateTime.now().millisecondsSinceEpoch}',
        'minEntrants': 4,
      });
    } on FirebaseFunctionsException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content:
                  Text('Failed to create tournament: ${e.message ?? e.code}')),
        );
      }
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  void _openTournament(String id) => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => TournamentDetailScreen(tournamentId: id)),
      );

  @override
  Widget build(BuildContext context) {
    final query = FirebaseFirestore.instance
        .collection('tournaments')
        .orderBy('createdAt', descending: true);

    return Scaffold(
      backgroundColor: const Color(0xFF070509),
      extendBodyBehindAppBar: true,
      // Transparent bar with only the back affordance - this is a pushed
      // route, not a tab, so it keeps its own back navigation (no bottom nav
      // is added here, per the "don't add a Tournaments tab" requirement).
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      floatingActionButton: AdminOnly(
        child: FloatingActionButton.extended(
          onPressed: _creating ? null : _createTestTournament,
          label: _creating
              ? const SizedBox(
                  height: 16,
                  width: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Create Test Tournament'),
          icon: _creating ? null : const Icon(Icons.add),
        ),
      ),
      body: Stack(
        children: [
          // Arena background: full width, top-centred, composition preserved
          // (fitWidth rather than cover, so the crown/crowd/stage/mics up top
          // are never aggressively cropped).
          Positioned.fill(
            child: Image.asset(
              _backgroundAsset,
              fit: BoxFit.fitWidth,
              alignment: Alignment.topCenter,
              errorBuilder: (_, _, _) =>
                  const ColoredBox(color: Color(0xFF070509)),
            ),
          ),
          // Let the arena show up top, then fall to near-black behind the UI.
          const Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Color(0x00000000),
                    Color(0x00000000),
                    Color(0x99070509),
                    Color(0xF2070509),
                    Color(0xFF070509),
                  ],
                  stops: [0.0, 0.26, 0.46, 0.60, 1.0],
                ),
              ),
            ),
          ),
          SafeArea(
            child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
              stream: query.snapshots(),
              builder: (context, snapshot) {
                return _buildContent(context, snapshot);
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildContent(
    BuildContext context,
    AsyncSnapshot<QuerySnapshot<Map<String, dynamic>>> snapshot,
  ) {
    final screenH = MediaQuery.of(context).size.height;
    // Keeps the title/list relatively high while preserving arena above it.
    final heroGap = (screenH * 0.20).clamp(96.0, 220.0);

    final docs = snapshot.data?.docs ?? const [];
    final byBucket = <_TournamentFilter, List<QueryDocumentSnapshot<Map<String, dynamic>>>>{
      _TournamentFilter.active: [],
      _TournamentFilter.upcoming: [],
      _TournamentFilter.completed: [],
    };
    for (final d in docs) {
      byBucket[_bucketOf(d.data())]!.add(d);
    }
    // The JOIN button targets a genuinely joinable tournament: the next
    // upcoming one, else one that is live now.
    final joinTarget = byBucket[_TournamentFilter.upcoming]!.isNotEmpty
        ? byBucket[_TournamentFilter.upcoming]!.first.id
        : byBucket[_TournamentFilter.active]!.isNotEmpty
            ? byBucket[_TournamentFilter.active]!.first.id
            : null;
    final selected = byBucket[_filter]!;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(height: heroGap),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 0),
          child: _TitleRow(
            onJoin: joinTarget == null
                ? () => ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                          content: Text(
                              'No tournament to join right now - check the '
                              'countdown on Home.')),
                    )
                : () => _openTournament(joinTarget),
          ),
        ),
        const SizedBox(height: 16),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: _FilterPills(
            selected: _filter,
            onChanged: (f) => setState(() => _filter = f),
          ),
        ),
        const SizedBox(height: 14),
        Expanded(
          child: _buildList(context, snapshot, selected),
        ),
      ],
    );
  }

  Widget _buildList(
    BuildContext context,
    AsyncSnapshot<QuerySnapshot<Map<String, dynamic>>> snapshot,
    List<QueryDocumentSnapshot<Map<String, dynamic>>> selected,
  ) {
    if (snapshot.hasError) {
      return _centered('Could not load tournaments. Pull to retry.');
    }
    if (!snapshot.hasData) {
      return const Center(child: CircularProgressIndicator());
    }
    if (selected.isEmpty) {
      return _centered(switch (_filter) {
        _TournamentFilter.active =>
          'No tournaments running right now.\nThe nightly one starts during the '
              'evening window.',
        _TournamentFilter.upcoming => 'Nothing scheduled yet.',
        _TournamentFilter.completed => 'No finished tournaments yet.',
      });
    }
    return ListView.builder(
      padding: EdgeInsets.fromLTRB(
          16, 0, 16, 16 + MediaQuery.of(context).padding.bottom),
      itemCount: selected.length,
      itemBuilder: (context, i) {
        final doc = selected[i];
        return _TournamentCard(
          data: doc.data(),
          thumbnailAsset: _backgroundAsset,
          onTap: () => _openTournament(doc.id),
        );
      },
    );
  }

  Widget _centered(String text) => Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Text(
            text,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Color(0xFF9A96A2),
              fontSize: 14,
              height: 1.4,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      );
}

// --- Buckets & derived data (all from the real tournament document) -------

/// Which segment a tournament belongs in, from its real status/timing.
_TournamentFilter _bucketOf(Map<String, dynamic> t) {
  final status = t['status'] as String? ?? 'open';
  if (status == 'completed' || status == 'cancelled') {
    return _TournamentFilter.completed;
  }
  if (status == 'in_progress') return _TournamentFilter.active;
  // Open: active if its start time has already passed, else upcoming.
  final now = DateTime.now().millisecondsSinceEpoch;
  final startsAt = (t['startsAtMs'] as num?)?.toInt() ??
      (t['windowStartMs'] as num?)?.toInt();
  if (startsAt != null && startsAt <= now) return _TournamentFilter.active;
  return _TournamentFilter.upcoming;
}

List<Map<String, dynamic>> _rounds(Map<String, dynamic> t) {
  final b = t['bracket'] as Map<String, dynamic>?;
  return (b?['rounds'] as List<dynamic>? ?? const [])
      .cast<Map<String, dynamic>>();
}

List<Map<String, dynamic>> _climbers(Map<String, dynamic> t) {
  final c = t['climb'] as Map<String, dynamic>?;
  return (c?['climbers'] as List<dynamic>? ?? const [])
      .cast<Map<String, dynamic>>();
}

int _playersInRound(Map<String, dynamic> round) {
  final matchups =
      (round['matchups'] as List<dynamic>? ?? const []).cast<Map<String, dynamic>>();
  var n = 0;
  for (final m in matchups) {
    if (m['player1Id'] != null) n++;
    if (m['player2Id'] != null) n++;
  }
  return n;
}

/// How many roasters are in this tournament (real players), or null.
int? _roasterCount(Map<String, dynamic> t) {
  if (t['format'] == 'climb') {
    final c = _climbers(t);
    return c.isEmpty ? null : c.length;
  }
  final rounds = _rounds(t);
  if (rounds.isEmpty) return null;
  return _playersInRound(rounds.first);
}

/// The full bracket size (power-of-two incl. byes), or the climb field size.
int? _fieldSize(Map<String, dynamic> t) {
  if (t['format'] == 'climb') {
    final c = _climbers(t);
    return c.isEmpty ? null : c.length;
  }
  final rounds = _rounds(t);
  if (rounds.isEmpty) return null;
  final matchups = (rounds.first['matchups'] as List<dynamic>? ?? const []);
  return matchups.length * 2;
}

/// How many are still alive, or null.
int? _aliveCount(Map<String, dynamic> t) {
  final status = t['status'] as String?;
  if (status == 'completed') return 1;
  if (t['format'] == 'climb') {
    final c = _climbers(t);
    if (c.isEmpty) return null;
    var n = 0;
    for (final m in c) {
      final s = m['status'] as String? ?? '';
      if (m['eliminated'] != true && s != 'eliminated') n++;
    }
    return n;
  }
  final rounds = _rounds(t);
  if (rounds.isEmpty) return null;
  return _playersInRound(rounds.last);
}

/// The current-stage label shown in pink, from real state.
String _stageLabel(Map<String, dynamic> t) {
  final status = t['status'] as String? ?? 'open';
  if (status == 'completed') return 'FINISHED';
  if (status == 'cancelled') return 'CANCELLED';
  if (t['format'] == 'climb') {
    return status == 'in_progress' ? 'LIVE' : 'GAUNTLET';
  }
  final rounds = _rounds(t);
  if (rounds.isEmpty || status != 'in_progress') return 'OPEN';
  final alive = _aliveCount(t) ?? 0;
  if (alive <= 2) return 'FINAL';
  if (alive <= 4) return 'SEMIFINALS';
  if (alive <= 8) return 'QUARTERFINALS';
  return 'ROUND ${rounds.length}';
}

/// "Next battle in ..." from the real start time, or null when not relevant.
String? _nextBattleLabel(Map<String, dynamic> t) {
  final status = t['status'] as String? ?? 'open';
  if (status == 'completed' || status == 'cancelled') return null;
  if (status == 'in_progress') return 'Live now';
  final startsAt = (t['startsAtMs'] as num?)?.toInt() ??
      (t['windowStartMs'] as num?)?.toInt();
  if (startsAt == null) return null;
  final d = startsAt - DateTime.now().millisecondsSinceEpoch;
  if (d <= 0) return 'Starting now';
  final mins = d ~/ 60000;
  if (mins < 60) return 'Next battle in ${mins}m';
  final hours = mins ~/ 60;
  if (hours < 24) return 'Next battle in ${hours}h';
  final days = hours ~/ 24;
  return 'Next battle in $days day${days == 1 ? '' : 's'}';
}

// --- Widgets ---------------------------------------------------------------

/// "MY TOURNAMENTS" + the pink outlined JOIN button.
class _TitleRow extends StatelessWidget {
  const _TitleRow({required this.onJoin});

  final VoidCallback onJoin;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        // Non-serif (inherits the theme's Inter base, not the serif display
        // face), bold, tracked - the same "modern UI" style as the Home pills.
        // FittedBox guards it from clipping on narrow screens.
        Flexible(
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              'MY TOURNAMENTS',
              style: TextStyle(
                fontWeight: FontWeight.w900,
                fontSize: 27,
                height: 1.0,
                letterSpacing: 0.4,
                color: Colors.white,
                shadows: const [Shadow(color: Colors.black, blurRadius: 10)],
              ),
            ),
          ),
        ),
        const SizedBox(width: 12),
        _JoinButton(onTap: onJoin),
      ],
    );
  }
}

class _JoinButton extends StatelessWidget {
  const _JoinButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final pink = context.palette.accent;
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(30),
      child: InkWell(
        borderRadius: BorderRadius.circular(30),
        onTap: onTap,
        child: Ink(
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.34),
            borderRadius: BorderRadius.circular(30),
            border: Border.all(color: pink, width: 1.4),
            // Restrained neon glow - present, not shouting.
            boxShadow: [
              BoxShadow(
                color: pink.withValues(alpha: 0.33),
                blurRadius: 13,
                spreadRadius: -3,
              ),
            ],
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.add, size: 17, color: pink),
                const SizedBox(width: 5),
                Text(
                  'JOIN TOURNAMENT',
                  style: TextStyle(
                    color: pink,
                    fontWeight: FontWeight.w800,
                    fontSize: 12,
                    letterSpacing: 0.4,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// One premium segmented control: ACTIVE | UPCOMING | COMPLETED.
class _FilterPills extends StatelessWidget {
  const _FilterPills({required this.selected, required this.onChanged});

  final _TournamentFilter selected;
  final ValueChanged<_TournamentFilter> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: const Color(0xFF0C0A12).withValues(alpha: 0.82),
        borderRadius: BorderRadius.circular(30),
        border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
      ),
      child: Row(
        children: [
          _seg(context, 'ACTIVE', _TournamentFilter.active),
          _seg(context, 'UPCOMING', _TournamentFilter.upcoming),
          _seg(context, 'COMPLETED', _TournamentFilter.completed),
        ],
      ),
    );
  }

  Widget _seg(BuildContext context, String label, _TournamentFilter f) {
    final isSel = f == selected;
    final pink = context.palette.accent;
    return Expanded(
      child: GestureDetector(
        onTap: () => onChanged(f),
        behavior: HitTestBehavior.opaque,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(vertical: 9),
          decoration: BoxDecoration(
            color: isSel ? pink : Colors.transparent,
            borderRadius: BorderRadius.circular(24),
          ),
          child: Center(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                label,
                style: TextStyle(
                  color: isSel ? const Color(0xFF15060C) : const Color(0xFF9A96A2),
                  fontWeight: FontWeight.w800,
                  fontSize: 12,
                  letterSpacing: 0.4,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// One compact horizontal tournament card - dark translucent, high
/// readability over the arena background, real data throughout.
class _TournamentCard extends StatelessWidget {
  const _TournamentCard({
    required this.data,
    required this.thumbnailAsset,
    required this.onTap,
  });

  final Map<String, dynamic> data;
  final String thumbnailAsset;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final pink = context.palette.accent;
    final gold = context.palette.reward;

    final name = data['name'] as String? ?? 'Tournament';
    final roasters = _roasterCount(data);
    final field = _fieldSize(data);
    final alive = _aliveCount(data);
    final stage = _stageLabel(data);
    final nextBattle = _nextBattleLabel(data);
    final isChampionship = name.toLowerCase().contains('championship');

    // Metadata line: "N Roasters • Single Elimination".
    final metaParts = <String>[
      if (roasters != null) '$roasters Roasters',
      'Single Elimination',
    ];

    final frac = (field != null && field > 0 && alive != null)
        ? (alive / field).clamp(0.0, 1.0)
        : null;

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          child: Ink(
            decoration: BoxDecoration(
              color: const Color(0xFF0D0B14).withValues(alpha: 0.86),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.white.withValues(alpha: 0.07)),
              boxShadow: const [
                BoxShadow(color: Color(0x33000000), blurRadius: 10, offset: Offset(0, 4)),
              ],
            ),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  // LEFT: square tournament artwork thumbnail.
                  ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: SizedBox(
                      width: 54,
                      height: 54,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          border: Border.all(
                              color: (isChampionship ? gold : Colors.white)
                                  .withValues(alpha: 0.18)),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Image.asset(
                          thumbnailAsset,
                          fit: BoxFit.cover,
                          alignment: Alignment.topCenter,
                          errorBuilder: (_, _, _) => ColoredBox(
                            color: const Color(0xFF1A1622),
                            child: Icon(Icons.emoji_events,
                                color: gold, size: 26),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  // CENTER: name, metadata, stage, next-battle.
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w800,
                            fontSize: 16,
                            height: 1.1,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          metaParts.join('  •  '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Color(0xFF9A96A2),
                            fontSize: 11.5,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          stage,
                          style: TextStyle(
                            color: pink,
                            fontWeight: FontWeight.w800,
                            fontSize: 12,
                            letterSpacing: 0.5,
                          ),
                        ),
                        if (nextBattle != null) ...[
                          const SizedBox(height: 2),
                          Text(
                            nextBattle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Color(0xFFB8B4C0),
                              fontSize: 11.5,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(width: 10),
                  // RIGHT: progression + thin pink bar.
                  if (frac != null) ...[
                    Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(
                          '$alive / $field',
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w800,
                            fontSize: 16,
                            fontFeatures: [FontFeature.tabularFigures()],
                          ),
                        ),
                        const Text(
                          'ROASTERS',
                          style: TextStyle(
                            color: Color(0xFF8C8896),
                            fontSize: 9,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.8,
                          ),
                        ),
                        const SizedBox(height: 6),
                        SizedBox(
                          width: 66,
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(3),
                            child: Stack(
                              children: [
                                Container(
                                    height: 4,
                                    color: Colors.white.withValues(alpha: 0.12)),
                                FractionallySizedBox(
                                  widthFactor: frac,
                                  child: Container(height: 4, color: pink),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(width: 6),
                  ],
                  Icon(Icons.chevron_right,
                      color: Colors.white.withValues(alpha: 0.5), size: 22),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
