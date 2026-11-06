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
/// from the top APPLICANTS who've judged the most that qualifying period), the
/// applicant roster ranked by judging volume, and the "Apply to judge" opt-in.
/// A seat is a coveted try-out, not a chore: you APPLY (a fixed, non-refundable
/// points fee when the flag is on - a sink that an active judge clears easily),
/// then judge enough battles to qualify, and the top applicants get the seats.
///
/// Cadence-neutral by design: the fee and the opt-in key off the canonical
/// qualifying-period (qualifyingWeek().cutoffDayKey). The cadence is weekly
/// (decided 2026-11-06), so this is one fee per week.
/// All server-published (stats/weeklyJudges); the opt-in + fee go through
/// HubService.volunteerToJudge (the internal id is unchanged).
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
  bool _volunteered = false; // "applied" (collection id is unchanged)
  bool _acting = false;
  // The apply fee, read from config/tournament. Off (free) until the flag flips.
  bool _feeEnabled = false;
  int _fee = 0;
  int _balance = 0;
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
      // The apply fee (config) + the viewer's balance, for the apply button.
      // The fee is only live when the tournament AND the fee flag are both on;
      // otherwise applying is free. 50 mirrors the server default.
      bool feeEnabled = false;
      int fee = 0;
      int balance = 0;
      final cfg = (await db.collection('config').doc('tournament').get()).data();
      if (cfg?['enabled'] == true && cfg?['judgeApplyFeeEnabled'] == true) {
        feeEnabled = true;
        final f = (cfg?['judgeApplyFee'] as num?)?.toInt();
        fee = (f != null && f >= 1) ? f : 50;
      }
      if (me != null) {
        final u = (await db.collection('users').doc(me).get()).data();
        balance = (u?['pointsBalance'] as num?)?.toInt() ??
            (u?['points'] as num?)?.toInt() ?? 0;
      }
      if (!mounted) return;
      setState(() {
        _volunteers = rows;
        _minToQualify =
            (data?['minToQualify'] as num?)?.toInt() ?? _defaultMinToQualify;
        _volunteered = volunteered;
        _feeEnabled = feeEnabled;
        _fee = fee;
        _balance = balance;
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _apply() async {
    if (_acting) return;
    // Spending points needs a confirm, and a non-refundable one doubly so.
    if (_feeEnabled) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Apply to judge?'),
          content: Text(
            'It costs $_fee points to throw your hat in for the next panel. '
            'It\'s non-refundable — win or lose the seat, the points are spent. '
            'Top applicants get the seats.',
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Apply')),
          ],
        ),
      );
      if (ok != true) return;
    }
    setState(() => _acting = true);
    try {
      await HubService.volunteerToJudge(true);
      if (!mounted) return;
      setState(() => _volunteered = true);
      await _load();
    } on FirebaseFunctionsException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.message ?? 'Could not apply.')),
        );
      }
    } finally {
      if (mounted) setState(() => _acting = false);
    }
  }

  Future<void> _withdraw() async {
    if (_acting) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Withdraw your application?'),
        content: Text(
          _feeEnabled
              ? "The points you spent to apply aren't refunded — but you can "
                  'apply again before the panel locks at no extra cost.'
              : 'You can apply again any time before the panel locks.',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Never mind')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Withdraw')),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _acting = true);
    try {
      await HubService.volunteerToJudge(false);
      if (!mounted) return;
      setState(() => _volunteered = false);
      await _load();
    } on FirebaseFunctionsException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.message ?? 'Could not withdraw.')),
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
          // Your application / status.
          _ApplyCard(
            applied: _volunteered,
            acting: _acting,
            feeEnabled: _feeEnabled,
            fee: _fee,
            balance: _balance,
            minToQualify: _minToQualify,
            gold: gold,
            onApply: _apply,
            onWithdraw: _withdraw,
          ),
          const SizedBox(height: 6),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Text('Applicants',
                style: text.labelLarge?.copyWith(
                    fontWeight: FontWeight.w800,
                    color: Colors.white.withValues(alpha: 0.8))),
          ),
          if (_volunteers.isEmpty)
            const Padding(
              padding: EdgeInsets.only(top: 24),
              child: EmptyState(
                icon: Icons.how_to_reg_outlined,
                title: 'No applicants yet',
                message: 'Be the first to throw your hat in. Apply, then '
                    'judge matches to climb the roster.',
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

class _ApplyCard extends StatelessWidget {
  const _ApplyCard({
    required this.applied,
    required this.acting,
    required this.feeEnabled,
    required this.fee,
    required this.balance,
    required this.minToQualify,
    required this.gold,
    required this.onApply,
    required this.onWithdraw,
  });

  final bool applied;
  final bool acting;
  final bool feeEnabled;
  final int fee;
  final int balance;
  final int minToQualify;
  final Color gold;
  final VoidCallback onApply;
  final VoidCallback onWithdraw;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final canAfford = !feeEnabled || balance >= fee;

    final String title;
    final String sub;
    if (applied) {
      title = 'Your application is in';
      sub = 'Keep judging to climb the roster — the top applicants get the '
          'open seats.';
    } else {
      title = 'Apply for a seat on the panel';
      sub = feeEnabled
          ? 'It costs $fee pts to apply, then judge $minToQualify matches to '
              'qualify. Top applicants get the seats.'
          : 'Apply, then judge $minToQualify matches to qualify.';
    }

    // The trailing action.
    Widget action;
    if (applied) {
      action = OutlinedButton(
        onPressed: acting ? null : onWithdraw,
        child: const Text('Withdraw'),
      );
    } else if (!canAfford) {
      // Can't cover the fee yet - judge more battles to earn it.
      action = Text('${fee - balance} more',
          style: text.labelMedium
              ?.copyWith(color: Colors.white.withValues(alpha: 0.6)));
    } else {
      action = FilledButton(
        onPressed: acting ? null : onApply,
        style: FilledButton.styleFrom(
            backgroundColor: gold, foregroundColor: const Color(0xFF3D2C00)),
        child: Text(feeEnabled ? 'Apply · $fee pts' : 'Apply'),
      );
    }

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        color: Colors.black.withValues(alpha: 0.35),
        border: Border.all(
            color: applied
                ? gold.withValues(alpha: 0.6)
                : Colors.white.withValues(alpha: 0.12)),
      ),
      child: Row(
        children: [
          Icon(applied ? Icons.how_to_reg : Icons.pan_tool_alt_outlined,
              color: applied ? gold : Colors.white.withValues(alpha: 0.7)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: text.titleSmall?.copyWith(
                        fontWeight: FontWeight.w800, color: Colors.white)),
                const SizedBox(height: 2),
                Text(sub,
                    style: text.bodySmall?.copyWith(
                        color: Colors.white.withValues(alpha: 0.7))),
              ],
            ),
          ),
          const SizedBox(width: 10),
          action,
        ],
      ),
    );
  }
}
