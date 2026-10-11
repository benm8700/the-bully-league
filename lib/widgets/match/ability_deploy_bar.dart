import 'package:flutter/material.dart';

import '../../core/services/abilities_service.dart';

/// Icon per ability id (new abilities fall back to a bolt).
IconData _iconFor(String id) {
  switch (id) {
    case 'interrupt':
      return Icons.front_hand;
    default:
      return Icons.flash_on;
  }
}

/// The in-match TAP-TO-DEPLOY bar for abilities bought in the pre-match
/// loadout (CLAUDE.md's power-ups, 2026-10-11).
///
/// It fetches the player's loadout, shows a compact button per equipped
/// ability with a remaining-count badge, and fires [onDeploy] when tapped,
/// decrementing the local remaining count so a one-shot ability can't be
/// spammed.
///
/// IMPORTANT: this is the BUTTON and its plumbing only. The in-match EFFECT of
/// a deploy (interrupt = steal the turn) is format-specific and applied by the
/// match engine - that is held for the round-times decision and wired into
/// [onDeploy]'s handler. Renders NOTHING when abilities are off in config (the
/// default) or the player brought none, so it stays dormant until then.
class AbilityDeployBar extends StatefulWidget {
  const AbilityDeployBar({
    super.key,
    required this.matchId,
    required this.onDeploy,
  });

  final String matchId;

  /// Called with the ability id when the player deploys one. The actual
  /// gameplay effect lives in the handler (format-specific, deferred).
  final void Function(String abilityId) onDeploy;

  @override
  State<AbilityDeployBar> createState() => _AbilityDeployBarState();
}

class _AbilityDeployBarState extends State<AbilityDeployBar> {
  Loadout? _loadout;
  final Map<String, int> _remaining = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final l = await AbilitiesService.getLoadout(widget.matchId);
      if (!mounted) return;
      setState(() {
        _loadout = l;
        for (final a in l.abilities) {
          _remaining[a.id] = a.total;
        }
      });
    } catch (_) {
      // Fail quiet - no bar. Deploying is a bonus, never a gate.
    }
  }

  void _deploy(AbilityOption a) {
    final left = _remaining[a.id] ?? 0;
    if (left <= 0) return;
    setState(() => _remaining[a.id] = left - 1);
    widget.onDeploy(a.id);
  }

  @override
  Widget build(BuildContext context) {
    final l = _loadout;
    if (l == null || !l.enabled) return const SizedBox.shrink();
    final deployable =
        l.abilities.where((a) => (_remaining[a.id] ?? 0) > 0).toList();
    if (deployable.isEmpty) return const SizedBox.shrink();

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final a in deployable) ...[
          _DeployButton(
            ability: a,
            remaining: _remaining[a.id] ?? 0,
            onTap: () => _deploy(a),
          ),
          const SizedBox(height: 8),
        ],
      ],
    );
  }
}

class _DeployButton extends StatelessWidget {
  const _DeployButton({
    required this.ability,
    required this.remaining,
    required this.onTap,
  });

  final AbilityOption ability;
  final int remaining;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: Colors.black.withValues(alpha: 0.55),
      borderRadius: BorderRadius.circular(22),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(22),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(_iconFor(ability.id), color: scheme.primary, size: 20),
              const SizedBox(width: 8),
              Text(
                ability.name,
                style: const TextStyle(
                    color: Colors.white, fontWeight: FontWeight.bold),
              ),
              const SizedBox(width: 8),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
                decoration: BoxDecoration(
                  color: scheme.primary,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text('×$remaining',
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.bold)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
