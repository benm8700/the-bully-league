import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import '../vote/my_battles_screen.dart';

/// The Rewards screen - where the points wallet is spent.
///
/// The Home screen used to carry a full milestone bar; the developer moved
/// that here (2026-09-14), leaving Home a slim "N Points / Rewards ->" wallet
/// line and putting the actual redemption in one place.
///
/// Two real sinks today (both from the points economy, functions/dayPass.js
/// and functions/clipGrants.js):
///  - a DAY PASS (24h anytime battling), redeemable right here since it is
///    account-level;
///  - a CAPTIONED CLIP of a battle, which is per-match, so this screen sends
///    the player to My Battles where each battle offers its own clip.
class RewardsScreen extends StatefulWidget {
  const RewardsScreen({super.key});

  @override
  State<RewardsScreen> createState() => _RewardsScreenState();
}

class _RewardsScreenState extends State<RewardsScreen> {
  bool _loading = true;
  bool _buying = false;
  String? _error;

  int _balance = 0;
  int _dayPassPrice = 300;
  int _clipPrice = 500;
  bool _dayPassEnabled = true;
  bool _dayPassActive = false;
  bool _boughtToday = false;

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
    try {
      final results = await Future.wait([
        FirebaseFunctions.instance.httpsCallable('getDayPassState').call(),
        FirebaseFirestore.instance
            .collection('config')
            .doc('pointsSettings')
            .get(),
      ]);
      final state = (results[0] as HttpsCallableResult).data as Map;
      final cfg = (results[1] as DocumentSnapshot<Map<String, dynamic>>).data();
      if (!mounted) return;
      setState(() {
        _balance = (state['balance'] as num?)?.toInt() ?? 0;
        _dayPassPrice = (state['price'] as num?)?.toInt() ?? _dayPassPrice;
        _dayPassEnabled = state['enabled'] != false;
        _dayPassActive = state['active'] == true;
        _boughtToday = state['boughtToday'] == true;
        final clip = (cfg?['clipPrice'] as num?)?.toInt();
        if (clip != null && clip > 0) _clipPrice = clip;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = "Couldn't load your rewards. Pull to try again.";
      });
    }
  }

  Future<void> _redeemDayPass() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Redeem a day pass?'),
        content: Text(
          'Spend $_dayPassPrice points for 24 hours of battling any time '
          'today, outside the nightly window.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Redeem'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _buying = true);
    try {
      await FirebaseFunctions.instance.httpsCallable('buyDayPass').call();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Day pass active - battle any time today.')),
      );
      await _load();
    } on FirebaseFunctionsException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.message ?? 'Could not redeem the day pass.')),
      );
    } finally {
      if (mounted) setState(() => _buying = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Rewards')),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
          children: [
            _balanceHeader(context),
            const SizedBox(height: 24),
            if (_loading)
              const Padding(
                padding: EdgeInsets.only(top: 48),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 40),
                child: Text(
                  _error!,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              )
            else ...[
              Text(
                'Redeem',
                style: Theme.of(context)
                    .textTheme
                    .titleMedium
                    ?.copyWith(fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 12),
              _dayPassCard(context),
              const SizedBox(height: 12),
              _clipCard(context),
            ],
          ],
        ),
      ),
    );
  }

  Widget _balanceHeader(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final gold = context.palette.currency;
    return Column(
      children: [
        Icon(Icons.monetization_on, color: gold, size: 34),
        const SizedBox(height: 8),
        Text(
          '$_balance',
          style: text.displaySmall?.copyWith(
            fontWeight: FontWeight.w900,
            color: gold,
          ),
        ),
        Text(
          'points to spend',
          style: text.bodyMedium?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }

  Widget _dayPassCard(BuildContext context) {
    final affordable = _balance >= _dayPassPrice;
    final String actionLabel;
    final VoidCallback? onAction;
    // The "owned" states (active now / already bought today) are highlighted
    // in the brand pink so a redeemed reward reads as clearly yours.
    var highlight = false;
    if (!_dayPassEnabled) {
      actionLabel = 'Unavailable';
      onAction = null;
    } else if (_dayPassActive) {
      actionLabel = 'Active';
      onAction = null;
      highlight = true;
    } else if (_boughtToday) {
      actionLabel = 'Bought today';
      onAction = null;
      highlight = true;
    } else if (!affordable) {
      actionLabel = '${_dayPassPrice - _balance} more';
      onAction = null;
    } else {
      actionLabel = 'Redeem';
      onAction = _buying ? null : _redeemDayPass;
    }
    return _RewardTile(
      emoji: '🎟️',
      title: 'Day pass',
      subtitle: 'Battle any time today,\noutside the nightly window.',
      price: _dayPassPrice,
      affordable: affordable,
      actionLabel: actionLabel,
      onAction: onAction,
      statusHighlight: highlight,
      busy: _buying,
    );
  }

  Widget _clipCard(BuildContext context) {
    final affordable = _balance >= _clipPrice;
    return _RewardTile(
      emoji: '🎬',
      title: 'Captioned clip',
      subtitle: 'The captioned cut of one of your battles - pick a battle to '
          'spend it on.',
      price: _clipPrice,
      affordable: affordable,
      actionLabel: 'My Battles',
      onAction: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const MyBattlesScreen()),
      ),
    );
  }
}

/// One redeemable reward row: emoji, title/subtitle, price, and an action.
class _RewardTile extends StatelessWidget {
  const _RewardTile({
    required this.emoji,
    required this.title,
    required this.subtitle,
    required this.price,
    required this.affordable,
    required this.actionLabel,
    required this.onAction,
    this.statusHighlight = false,
    this.busy = false,
  });

  final String emoji;
  final String title;
  final String subtitle;
  final int price;
  final bool affordable;
  final String actionLabel;
  final VoidCallback? onAction;

  /// When the trailing is a STATUS (no action) that should stand out - the
  /// "Active" / "Bought today" owned states - it's drawn in the brand pink.
  final bool statusHighlight;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final gold = context.palette.currency;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: scheme.surfaceContainer,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Row(
        children: [
          Text(emoji, style: const TextStyle(fontSize: 26)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      title,
                      style: text.titleSmall
                          ?.copyWith(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '$price pts',
                      style: text.labelMedium?.copyWith(
                        color: gold,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  subtitle,
                  style: text.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                    height: 1.2,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          busy
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : onAction != null
                  ? FilledButton(
                      onPressed: onAction,
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 8),
                        visualDensity: VisualDensity.compact,
                      ),
                      child: Text(actionLabel),
                    )
                  : Text(
                      actionLabel,
                      style: text.labelMedium?.copyWith(
                        color: statusHighlight
                            ? context.palette.accent
                            : scheme.onSurfaceVariant,
                        fontWeight:
                            statusHighlight ? FontWeight.w800 : FontWeight.w600,
                      ),
                    ),
        ],
      ),
    );
  }
}
