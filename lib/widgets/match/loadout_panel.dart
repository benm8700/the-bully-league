import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';

import '../../core/services/abilities_service.dart';

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
    if (_busyId != null) return;
    setState(() => _busyId = a.id);
    try {
      await AbilitiesService.buyAbility(
          matchId: widget.matchId, abilityId: a.id);
      await _load();
    } on FirebaseFunctionsException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.message ?? "Couldn't add that.")),
      );
    } catch (_) {
      if (!mounted) return;
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
              'Bring weapons to throw them off. Tap to deploy mid-battle.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            for (final a in l.abilities) _AbilityRow(
              ability: a,
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
    required this.busy,
    required this.onBuy,
  });

  final AbilityOption ability;
  final bool busy;
  final VoidCallback onBuy;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
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
                if (ability.free > 0)
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
    );
  }

  Widget _buyControl(BuildContext context) {
    if (busy) {
      return const SizedBox(
        width: 92,
        height: 36,
        child: Center(
          child: SizedBox(
              width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
        ),
      );
    }
    if (ability.atCap) {
      return SizedBox(
        width: 92,
        child: Text('Maxed',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.labelMedium),
      );
    }
    return SizedBox(
      width: 92,
      child: OutlinedButton(
        onPressed: ability.canBuy ? onBuy : null,
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
