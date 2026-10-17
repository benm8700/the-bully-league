import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';

import '../../core/services/abilities_service.dart';
import 'ability_deploy_bar.dart' show abilityIcon;

/// The pre-match LOADOUT (CLAUDE.md's abilities/power-ups, 2026-10-11).
///
/// Shown inline on the ready-up screen so a player can bring "weapons" to
/// throw their opponent off before the battle starts. Self-contained: it
/// fetches its own loadout and renders NOTHING when abilities are switched off
/// in config (the default today) or the match doesn't allow them - so it is
/// safe to mount everywhere and only appears once the economy is turned on.
///
/// Buying commits to a server-only per-match loadout (secret from the
/// opponent). Points are spent server-side; this never trusts the client.
class LoadoutPanel extends StatefulWidget {
  const LoadoutPanel({super.key, required this.matchId});

  final String matchId;

  @override
  State<LoadoutPanel> createState() => _LoadoutPanelState();
}

class _LoadoutPanelState extends State<LoadoutPanel> {
  Loadout? _loadout;
  bool _loaded = false;
  String? _busyId;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final l = await AbilitiesService.getLoadout(widget.matchId);
      if (mounted) setState(() => _loadout = l);
    } catch (_) {
      // Fail quiet: a loadout fetch that fails just shows no panel. It is a
      // pre-match extra, never a gate on playing.
    } finally {
      if (mounted) setState(() => _loaded = true);
    }
  }

  Future<void> _buy(AbilityOption a) async {
    final before = _loadout;
    if (_busyId != null || before == null || !a.canBuy) return;
    // Optimistic: reflect the purchase INSTANTLY so the button doesn't feel
    // laggy waiting on the callable. Reconcile with the server's exact
    // bought/balance when it returns; revert to `before` if it fails.
    setState(() {
      _busyId = a.id;
      _loadout =
          before.withPurchase(a.id, bought: a.bought + 1, balance: before.balance - a.cost);
    });
    try {
      final res = await AbilitiesService.buyAbility(
          matchId: widget.matchId, abilityId: a.id);
      final nb = (res['bought'] as num?)?.toInt();
      final bal = (res['balance'] as num?)?.toInt();
      if (mounted && nb != null && bal != null) {
        setState(() =>
            _loadout = (_loadout ?? before).withPurchase(a.id, bought: nb, balance: bal));
      }
    } on FirebaseFunctionsException catch (e) {
      if (!mounted) return;
      setState(() => _loadout = before); // revert the optimistic bump
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.message ?? "Couldn't add that.")),
      );
    } catch (_) {
      if (!mounted) return;
      setState(() => _loadout = before);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Couldn't add that - try again.")),
      );
    } finally {
      if (mounted) setState(() => _busyId = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = _loadout;
    // Nothing until it's loaded, and nothing if abilities are off / none apply.
    if (!_loaded || l == null || !l.hasAny) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Card(
      margin: const EdgeInsets.only(top: 20),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.flash_on, size: 18, color: scheme.primary),
                const SizedBox(width: 6),
                Text('Your loadout', style: theme.textTheme.titleMedium),
                const Spacer(),
                Text('${l.balance} pts',
                    style: theme.textTheme.labelLarge
                        ?.copyWith(color: scheme.primary)),
              ],
            ),
            const SizedBox(height: 2),
            Text(
              l.friendFree
                  ? "It's a friend battle - everything's free. Bring anything."
                  : 'Bring weapons to throw them off. Unlock more as you rank up.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            for (final a in l.abilities) _AbilityRow(
              ability: a,
              friendFree: l.friendFree,
              busy: _busyId == a.id,
              onBuy: () => _buy(a),
            ),
          ],
        ),
      ),
    );
  }
}

class _AbilityRow extends StatelessWidget {
  const _AbilityRow({
    required this.ability,
    required this.friendFree,
    required this.busy,
    required this.onBuy,
  });

  final AbilityOption ability;
  final bool friendFree;
  final bool busy;
  final VoidCallback onBuy;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    // Locked abilities are dimmed - visible as a goal, not usable yet.
    final locked = !ability.unlocked;
    return Opacity(
      opacity: locked ? 0.45 : 1,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Icon(locked ? Icons.lock_outline : abilityIcon(ability.id),
                size: 22, color: scheme.primary),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(ability.name, style: theme.textTheme.titleSmall),
                      if (ability.total > 0) ...[
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 7, vertical: 2),
                          decoration: BoxDecoration(
                            color: scheme.primary.withValues(alpha: 0.18),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text('×${ability.total}',
                              style: theme.textTheme.labelMedium
                                  ?.copyWith(color: scheme.primary)),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(ability.description, style: theme.textTheme.bodySmall),
                  if (friendFree)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text('Free in this friend battle',
                          style: theme.textTheme.labelSmall
                              ?.copyWith(color: scheme.primary)),
                    )
                  else if (ability.free > 0)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        '${ability.free} included with your membership',
                        style: theme.textTheme.labelSmall
                            ?.copyWith(color: scheme.primary),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            _buyControl(context),
          ],
        ),
      ),
    );
  }

  Widget _buyControl(BuildContext context) {
    final theme = Theme.of(context);
    // Locked: show the rank it unlocks at instead of a buy button.
    if (!ability.unlocked) {
      return SizedBox(
        width: 92,
        child: Text(
          ability.unlockTitle != null
              ? 'Unlock at\n${ability.unlockTitle}'
              : 'Locked',
          textAlign: TextAlign.center,
          style: theme.textTheme.labelSmall,
        ),
      );
    }
    // Friend battle: everything's already yours, free.
    if (friendFree) {
      return SizedBox(
        width: 92,
        child: Text('Free',
            textAlign: TextAlign.center,
            style: theme.textTheme.labelMedium
                ?.copyWith(color: theme.colorScheme.primary)),
      );
    }
    if (ability.atCap) {
      return SizedBox(
        width: 92,
        child: Text('Maxed',
            textAlign: TextAlign.center,
            style: theme.textTheme.labelMedium),
      );
    }
    // No spinner: the count bumps optimistically on tap, so the button just
    // disables briefly while the purchase confirms.
    return SizedBox(
      width: 92,
      child: OutlinedButton(
        onPressed: (ability.canBuy && !busy) ? onBuy : null,
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          visualDensity: VisualDensity.compact,
        ),
        child: Text(
          'Add · ${ability.cost}',
          style: const TextStyle(fontSize: 12),
          overflow: TextOverflow.ellipsis,
        ),
      ),
    );
  }
}
