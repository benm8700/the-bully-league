import 'package:flutter/material.dart';

import '../../core/services/prize_service.dart';
import '../../screens/prizes/prize_claim_screen.dart';

/// Shows on Home when the player has won a non-cash prize they haven't claimed
/// yet, and taps through to the claim form. This is the reliable in-app path
/// (the prize-won push just opens the app), the same role the active-match and
/// gauntlet banners play. Renders nothing when there's nothing to claim.
class PrizeClaimBanner extends StatefulWidget {
  const PrizeClaimBanner({super.key});

  @override
  State<PrizeClaimBanner> createState() => _PrizeClaimBannerState();
}

class _PrizeClaimBannerState extends State<PrizeClaimBanner>
    with WidgetsBindingObserver {
  final _service = PrizeService();
  List<OwedPrize> _owed = const [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Re-check on resume, so a prize won while the app was backgrounded (and
    // pushed) shows the moment they come back.
    if (state == AppLifecycleState.resumed) _load();
  }

  Future<void> _load() async {
    final owed = await _service.myOwedPrizes();
    if (mounted) setState(() => _owed = owed);
  }

  Future<void> _open(OwedPrize prize) async {
    final claimed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => PrizeClaimScreen(prize: prize)),
    );
    if (claimed == true) _load(); // it's no longer "owed" once claimed
  }

  @override
  Widget build(BuildContext context) {
    if (_owed.isEmpty) return const SizedBox.shrink();
    final prize = _owed.first;
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Material(
        color: scheme.tertiaryContainer,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () => _open(prize),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              children: [
                Icon(Icons.card_giftcard, color: scheme.onTertiaryContainer),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '🎉 You won ${prize.prize}!',
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                            color: scheme.onTertiaryContainer,
                            fontWeight: FontWeight.w800),
                      ),
                      Text(
                        'Tap to claim and tell us where to send it.',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: scheme.onTertiaryContainer.withValues(
                                alpha: 0.85)),
                      ),
                    ],
                  ),
                ),
                Icon(Icons.chevron_right, color: scheme.onTertiaryContainer),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
