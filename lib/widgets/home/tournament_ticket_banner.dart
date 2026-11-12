import 'package:flutter/material.dart';

import '../../core/services/tournament_ticket_service.dart';
import '../../theme/app_theme.dart';
import '../neon_dialog.dart';

/// Home nudge: "Secure your ticket for the tournament."
///
/// The try-out ticket is the weekly ENTRY PASS into the Main Stage - buy it by
/// the Wednesday-night deadline and your ranked play this period becomes
/// eligible to be picked up for the finals; skip it and you still battle, you
/// just won't get drawn into the field. This banner is the reminder to grab it
/// before the cutoff, and it doubles as the signal of who actually means to
/// compete.
///
/// Self-gating like the other Home banners: renders NOTHING when ticketing is
/// off, when the state can't be reached, or once the ticket is already held -
/// so Home stays clean and a secured ticket stops nagging. Chosen as a
/// persistent banner rather than a forced pop-up: a modal on every Home open
/// would be the annoying version of this, and a banner matches the app's
/// existing Main Stage / event surfaces while staying highly visible.
class TournamentTicketBanner extends StatefulWidget {
  const TournamentTicketBanner({super.key, this.service});

  final TournamentTicketService? service;

  @override
  State<TournamentTicketBanner> createState() => _TournamentTicketBannerState();
}

class _TournamentTicketBannerState extends State<TournamentTicketBanner> {
  late final TournamentTicketService _service =
      widget.service ?? TournamentTicketService();

  TournamentTicketState? _state;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final s = await _service.state();
    if (mounted) setState(() => _state = s);
  }

  Future<void> _secure() async {
    final s = _state;
    if (s == null) return;
    final confirmed = await _confirm(s);
    if (confirmed != true || !mounted) return;
    setState(() => _busy = true);
    try {
      await _service.secure();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("You're in — your spot is secured.")),
      );
      await _load(); // now held -> the banner hides itself
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("Couldn't secure your ticket. Try again."),
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<bool?> _confirm(TournamentTicketState s) {
    final body = s.member
        ? 'Your membership covers it — claim your spot in this '
              "week's tournament. You won't be charged any points."
        : 'This costs ${s.price} points and is spent whether or not you make '
              'the finals — it enters you in the race. You have ${s.balance}.';
    return showDialog<bool>(
      context: context,
      builder: (ctx) => NeonDialog(
        title: const Text('Secure your tournament ticket'),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Not now'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(s.member ? 'Claim my spot' : 'Secure · ${s.price} pts'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = _state;
    if (s == null || !s.showPrompt) return const SizedBox.shrink();

    final gold = context.palette.reward;
    final onVariant = Theme.of(context).colorScheme.onSurfaceVariant;
    final affordable = s.affordable;

    final String sub;
    if (s.member) {
      sub = 'Included with your membership. Get it before Wednesday night.';
    } else if (affordable) {
      sub = '${s.price} pts to enter. Get it before Wednesday night.';
    } else {
      final need = s.price - s.balance;
      sub = 'Costs ${s.price} pts — earn $need more by Wednesday night.';
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: gold.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: _busy ? null : _secure,
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: gold.withValues(alpha: 0.45)),
            ),
            padding: const EdgeInsets.all(14),
            child: Row(
              children: [
                Icon(Icons.confirmation_number, color: gold),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Secure your tournament ticket',
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w800,
                          color: gold,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        sub,
                        style: Theme.of(
                          context,
                        ).textTheme.bodySmall?.copyWith(color: onVariant),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                if (_busy)
                  const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else
                  Icon(Icons.chevron_right, color: gold),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
