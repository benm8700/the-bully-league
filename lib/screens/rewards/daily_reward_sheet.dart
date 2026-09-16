import 'package:flutter/material.dart';

import '../../core/services/daily_reward_service.dart';

/// The Free Rewards claim sheet: a daily login reward on an escalating
/// 7-day cycle, claimed once per Pacific day (see functions/dailyReward.js).
///
/// Reward/event surfaces are GOLD in this app's colour language (identity is
/// purple; event/reward is gold), so the whole sheet reads gold.
class DailyRewardSheet extends StatefulWidget {
  const DailyRewardSheet({super.key, this.service});

  final DailyRewardService? service;

  /// Opens the sheet. Returns true if a reward was claimed while it was open,
  /// so the caller can refresh any "claim ready" indicator.
  static Future<bool> show(BuildContext context, {DailyRewardService? service}) async {
    final claimed = await showModalBottomSheet<bool>(
      context: context,
      showDragHandle: true,
      backgroundColor: const Color(0xFF121016),
      isScrollControlled: true,
      builder: (_) => DailyRewardSheet(service: service),
    );
    return claimed ?? false;
  }

  @override
  State<DailyRewardSheet> createState() => _DailyRewardSheetState();
}

class _DailyRewardSheetState extends State<DailyRewardSheet> {
  static const _gold = Color(0xFFFFC107);
  static const _goldDeep = Color(0xFFD9A21E);

  late final DailyRewardService _service = widget.service ?? DailyRewardService();

  DailyRewardState? _state;
  bool _loading = true;
  bool _claiming = false;
  bool _claimedHere = false;
  String? _error;
  int? _justAwarded;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final state = await _service.state();
    if (!mounted) return;
    setState(() {
      _state = state;
      _loading = false;
      if (state == null) _error = "Couldn't load your rewards. Try again.";
    });
  }

  Future<void> _claim() async {
    setState(() => _claiming = true);
    try {
      final result = await _service.claim();
      if (!mounted) return;
      setState(() {
        _claiming = false;
        _claimedHere = true;
        _justAwarded = result.reward;
      });
      // Refresh so the calendar shows today as claimed and the button flips
      // to the come-back-tomorrow state.
      await _load();
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _claiming = false;
        _error = 'That didn\'t work. You may have already claimed today.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          20, 4, 20, 20 + MediaQuery.of(context).padding.bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(Icons.redeem, color: _gold, size: 24),
                const SizedBox(width: 10),
                Text(
                  'Free Rewards',
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.w800,
                      ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'Come back every day. Miss a day and the streak resets.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: const Color(0xFFA0A0A0),
                  ),
            ),
            const SizedBox(height: 18),
            _body(context),
          ],
        ),
      ),
    );
  }

  Widget _body(BuildContext context) {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 40),
        child: Center(child: CircularProgressIndicator(color: _gold)),
      );
    }
    final state = _state;
    if (state == null) {
      return Column(
        children: [
          Text(
            _error ?? "Couldn't load your rewards.",
            style: const TextStyle(color: Color(0xFFA0A0A0)),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          OutlinedButton(onPressed: _load, child: const Text('Try again')),
        ],
      );
    }
    if (!state.enabled) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Text(
          "Daily rewards aren't running right now.",
          style: TextStyle(color: Color(0xFFA0A0A0)),
          textAlign: TextAlign.center,
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _CycleRow(
          schedule: state.schedule,
          cycleDay: state.cycleDay,
          claimedToday: state.claimedToday,
        ),
        const SizedBox(height: 20),
        _action(state),
      ],
    );
  }

  Widget _action(DailyRewardState state) {
    if (state.claimable) {
      return _GoldButton(
        onPressed: _claiming ? null : _claim,
        child: _claiming
            ? const SizedBox(
                height: 20,
                width: 20,
                child: CircularProgressIndicator(
                    strokeWidth: 2.5, color: Color(0xFF3A2A00)),
              )
            : Text('Claim ${state.todaysReward} points'),
      );
    }
    // Claimed today: quiet come-back-tomorrow state, with a fresh "+N" line
    // if the claim happened in this session.
    return Column(
      children: [
        if (_claimedHere && _justAwarded != null) ...[
          Text(
            '+$_justAwarded points',
            style: const TextStyle(
              color: _gold,
              fontSize: 22,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 6),
        ],
        const Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.check_circle, color: _goldDeep, size: 18),
            SizedBox(width: 8),
            Text(
              'Claimed today — come back tomorrow',
              style: TextStyle(color: Color(0xFFCFCFCF), fontWeight: FontWeight.w600),
            ),
          ],
        ),
      ],
    );
  }
}

/// The 7-day cycle as a row of compact day tiles: claimed days checked,
/// today ringed and lit, future days dimmed, the final day accented as the
/// climax.
class _CycleRow extends StatelessWidget {
  const _CycleRow({
    required this.schedule,
    required this.cycleDay,
    required this.claimedToday,
  });

  final List<int> schedule;
  final int cycleDay;
  final bool claimedToday;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        for (var i = 0; i < schedule.length; i++) ...[
          if (i > 0) const SizedBox(width: 6),
          Expanded(
            child: _DayTile(
              day: i + 1,
              points: schedule[i],
              // A day is "done" if it's before today's cycle day, or it's
              // today and already claimed.
              claimed: (i + 1) < cycleDay ||
                  ((i + 1) == cycleDay && claimedToday),
              isToday: (i + 1) == cycleDay,
              isFinal: i == schedule.length - 1,
            ),
          ),
        ],
      ],
    );
  }
}

class _DayTile extends StatelessWidget {
  const _DayTile({
    required this.day,
    required this.points,
    required this.claimed,
    required this.isToday,
    required this.isFinal,
  });

  final int day;
  final int points;
  final bool claimed;
  final bool isToday;
  final bool isFinal;

  static const _gold = Color(0xFFFFC107);

  @override
  Widget build(BuildContext context) {
    final active = isToday && !claimed;
    final Color border = active
        ? _gold
        : claimed
            ? _gold.withValues(alpha: 0.55)
            : Colors.white.withValues(alpha: 0.10);
    final Color bg = active
        ? _gold.withValues(alpha: 0.14)
        : const Color(0xFF1A1620);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: border, width: active ? 1.6 : 1),
        boxShadow: active
            ? [BoxShadow(color: _gold.withValues(alpha: 0.25), blurRadius: 12, spreadRadius: -3)]
            : null,
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 2),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                isFinal ? 'DAY $day' : 'D$day',
                style: TextStyle(
                  fontSize: 8.5,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.3,
                  color: isFinal
                      ? _gold
                      : const Color(0xFF8A8A8A),
                ),
              ),
            ),
            const SizedBox(height: 5),
            SizedBox(
              height: 20,
              child: claimed
                  ? Icon(Icons.check_circle, color: _gold.withValues(alpha: 0.9), size: 18)
                  : Icon(
                      isFinal ? Icons.emoji_events : Icons.stars,
                      color: active
                          ? _gold
                          : (isFinal ? _gold.withValues(alpha: 0.8) : const Color(0xFF6E6A66)),
                      size: isFinal ? 18 : 15,
                    ),
            ),
            const SizedBox(height: 4),
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                '$points',
                style: TextStyle(
                  fontSize: isFinal ? 13 : 11.5,
                  fontWeight: FontWeight.w800,
                  color: claimed || active || isFinal
                      ? Colors.white
                      : const Color(0xFF9A9A9A),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A custom gold gradient button — a plain FilledButton can't gradient, and
/// gold is the reward accent used across the app's event/reward surfaces.
class _GoldButton extends StatelessWidget {
  const _GoldButton({required this.onPressed, required this.child});

  final VoidCallback? onPressed;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onPressed,
        child: Ink(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            gradient: const LinearGradient(
              colors: [Color(0xFFF6D66B), Color(0xFFFFC107), Color(0xFFD9A21E)],
            ),
            border: Border.all(color: const Color(0xFF7A5A12)),
          ),
          child: Container(
            height: 52,
            alignment: Alignment.center,
            child: DefaultTextStyle.merge(
              style: const TextStyle(
                color: Color(0xFF3A2A00),
                fontWeight: FontWeight.w900,
                fontSize: 16,
              ),
              child: child,
            ),
          ),
        ),
      ),
    );
  }
}
