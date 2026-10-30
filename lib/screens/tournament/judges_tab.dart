import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../../core/services/hub_service.dart';
import '../../core/services/main_stage_service.dart';
import '../../theme/app_theme.dart';
import '../../widgets/empty_state.dart';
import '../profile/performer_profile_screen.dart';
import 'judges_room_screen.dart';

/// The Judges tab of the tournament hub.
///
/// Shows how a panel is filled (the founder picks a few seats; the rest autofill
/// from the top VOLUNTEERS who've judged the most this week), this week's
/// volunteer roster ranked by judging volume, and the "I'll judge" opt-in.
/// Judging a live panel is a role you CHOOSE - you volunteer, then judge enough
/// battles to qualify for a seat. All server-published (stats/weeklyJudges); the
/// opt-in goes through HubService.volunteerToJudge.
class JudgesTab extends StatefulWidget {
  const JudgesTab({super.key, required this.weekKey});

  /// The current hub week (from getHubRoom). Null only if that call failed.
  final String? weekKey;

  @override
  State<JudgesTab> createState() => _JudgesTabState();
}

/// Display fallback for the qualify bar before the board loads - matches the
/// server default in hubJudges.resolveJudgeMinToQualify.
const int _defaultMinToQualify = 10;

class _JudgesTabState extends State<JudgesTab> {
  bool _loading = true;
  List<Map<String, dynamic>> _volunteers = const [];
  final Map<String, String> _names = {};
  int _minToQualify = _defaultMinToQualify;
  bool _volunteered = false;
  bool _acting = false;
  final _mainStage = MainStageService();

  String? get _uid => FirebaseAuth.instance.currentUser?.uid;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(JudgesTab old) {
    super.didUpdateWidget(old);
    // The hub loads weekKey a beat after this tab first builds, so the initial
    // _load often ran with a null weekKey and couldn't read the volunteer doc
    // (showing "not volunteered" even after a successful opt-in). Re-read once
    // the key arrives so the state reflects the server, not a stale first pass.
    if (old.weekKey != widget.weekKey && widget.weekKey != null) {
      _load();
    }
  }

  Future<void> _load() async {
    try {
      final db = FirebaseFirestore.instance;
      final doc = await db.collection('stats').doc('weeklyJudges').get();
      final data = doc.data();
      final raw = (data?['volunteers'] as List?) ?? const [];
      final rows = raw
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .where((e) => e['uid'] is String)
          .take(30)
          .toList();
      final uids = rows.map((e) => e['uid'] as String).toList();
      if (uids.isNotEmpty) {
        final q = await db
            .collection('users')
            .where(FieldPath.documentId, whereIn: uids)
            .get();
        for (final d in q.docs) {
          final n = d.data()['username'];
          if (n is String) _names[d.id] = n;
        }
      }
      bool volunteered = false;
      final wk = widget.weekKey;
      final me = _uid;
      if (wk != null && me != null) {
        final v = await db
            .collection('judgeVolunteers')
            .doc(wk)
            .collection('volunteers')
            .doc(me)
            .get();
        volunteered = v.exists;
      }
      if (!mounted) return;
      setState(() {
        _volunteers = rows;
        _minToQualify =
            (data?['minToQualify'] as num?)?.toInt() ?? _defaultMinToQualify;
        _volunteered = volunteered;
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _toggleVolunteer() async {
    if (_acting) return;
    setState(() => _acting = true);
    final want = !_volunteered;
    try {
      final now = await HubService.volunteerToJudge(want);
      if (!mounted) return;
      setState(() => _volunteered = now);
      await _load();
    } on FirebaseFunctionsException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.message ?? 'Could not update.')),
        );
      }
    } finally {
      if (mounted) setState(() => _acting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    final gold = context.palette.reward;
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final selfUid = _uid;

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(0, 8, 0, 24),
        children: [
          // If you're a seated judge and a battle is on stage right now, the
          // fastest way in - straight to the judges' room.
          _liveJudgeCta(),
          // How the panel gets filled.
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.gavel, color: gold, size: 20),
                    const SizedBox(width: 8),
                    Text('Judge the Main Stage',
                        style: text.titleMedium?.copyWith(
                            fontWeight: FontWeight.w800, color: gold)),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  'Earn your way onto the panel and judge the Main Stage live — '
                  'on camera, in front of the whole League. Your verdict, your '
                  'moment to shine, your spot on the show.',
                  style:
                      text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
          // Your opt-in / status.
          _StatusCard(
            volunteered: _volunteered,
            acting: _acting,
            onToggle: _toggleVolunteer,
            minToQualify: _minToQualify,
            gold: gold,
          ),
          const SizedBox(height: 6),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Text("This week's volunteers",
                style: text.labelLarge?.copyWith(
                    fontWeight: FontWeight.w800,
                    color: Colors.white.withValues(alpha: 0.8))),
          ),
          if (_volunteers.isEmpty)
            const Padding(
              padding: EdgeInsets.only(top: 24),
              child: EmptyState(
                icon: Icons.how_to_reg_outlined,
                title: 'No volunteers yet',
                message: 'Be the first to put your hand up. Volunteer, then '
                    'vote on matches to climb the roster.',
              ),
            )
          else
            ..._volunteers.asMap().entries.map((e) =>
                _row(e.key, e.value, selfUid, gold, text, scheme)),
        ],
      ),
    );
  }

  /// Shown only to a seated judge while a battle is live on stage: a direct
  /// button into the judges' room. The alert bar and Home banner cover this
  /// too; this is the in-hub path the developer asked for.
  Widget _liveJudgeCta() {
    return StreamBuilder<MainStageView?>(
      stream: _mainStage.watch(),
      builder: (context, snap) {
        final v = snap.data;
        if (v == null ||
            v.status != 'live' ||
            v.role != MainStageRole.judge ||
            v.liveBattleMatchId == null) {
          return const SizedBox.shrink();
        }
        final mid = v.liveBattleMatchId!;
        final live = context.palette.live;
        return Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
          child: SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: live,
                foregroundColor: Colors.white,
                minimumSize: const Size(0, 52),
              ),
              icon: const Icon(Icons.gavel),
              label: const Text("Join the judges' room"),
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => JudgesRoomScreen(matchId: mid))),
            ),
          ),
        );
      },
    );
  }

  Widget _row(int i, Map<String, dynamic> e, String? selfUid, Color gold,
      TextTheme text, ColorScheme scheme) {
    final uid = e['uid'] as String;
    final judged = (e['judged'] as num?)?.toInt() ?? 0;
    final qualified = e['qualified'] == true;
    final isSelf = uid == selfUid;
    final name = _names[uid] ?? 'Roaster';
    return Material(
      color: isSelf ? gold.withValues(alpha: 0.14) : Colors.transparent,
      child: ListTile(
        dense: true,
        visualDensity: const VisualDensity(vertical: -3),
        onTap: () => Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => PerformerProfileScreen(uid: uid))),
        leading: Text('${i + 1}',
            style: TextStyle(
                fontWeight: FontWeight.w900,
                fontSize: 16,
                color: qualified ? gold : scheme.onSurfaceVariant)),
        title: Text(
          isSelf ? '$name  (you)' : name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
              fontWeight: isSelf ? FontWeight.w800 : FontWeight.w600),
        ),
        subtitle: Text(
          qualified
              ? 'Qualified · $judged votes'
              : '${_minToQualify - judged} more to qualify · $judged votes',
          style: TextStyle(
              color: qualified ? gold : scheme.onSurfaceVariant, fontSize: 11),
        ),
        trailing: qualified
            ? Icon(Icons.check_circle, color: gold, size: 18)
            : null,
      ),
    );
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({
    required this.volunteered,
    required this.acting,
    required this.onToggle,
    required this.minToQualify,
    required this.gold,
  });

  final bool volunteered;
  final bool acting;
  final VoidCallback onToggle;
  final int minToQualify;
  final Color gold;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        color: Colors.black.withValues(alpha: 0.35),
        border: Border.all(
            color: volunteered
                ? gold.withValues(alpha: 0.6)
                : Colors.white.withValues(alpha: 0.12)),
      ),
      child: Row(
        children: [
          Icon(volunteered ? Icons.how_to_reg : Icons.pan_tool_alt_outlined,
              color: volunteered ? gold : Colors.white.withValues(alpha: 0.7)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  volunteered
                      ? "You're in for this week"
                      : 'Want a seat on the panel?',
                  style: text.titleSmall?.copyWith(
                      fontWeight: FontWeight.w800, color: Colors.white),
                ),
                const SizedBox(height: 2),
                Text(
                  volunteered
                      ? 'Keep voting to climb the roster — top volunteers get '
                          'the open seats.'
                      : 'Volunteer, then vote on $minToQualify matches this week '
                          'to qualify.',
                  style: text.bodySmall
                      ?.copyWith(color: Colors.white.withValues(alpha: 0.7)),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          volunteered
              ? OutlinedButton(
                  onPressed: acting ? null : onToggle,
                  child: const Text('Withdraw'),
                )
              : FilledButton(
                  onPressed: acting ? null : onToggle,
                  style: FilledButton.styleFrom(
                      backgroundColor: gold,
                      foregroundColor: const Color(0xFF3D2C00)),
                  child: const Text('Volunteer'),
                ),
        ],
      ),
    );
  }
}
