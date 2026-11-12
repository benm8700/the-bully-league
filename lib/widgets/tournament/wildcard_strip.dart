import 'package:flutter/material.dart';

import '../../core/services/wildcard_auction_service.dart';
import '../../screens/tournament/wildcard_bid_sheet.dart';
import '../../theme/app_theme.dart';

/// The two discoverable entry points to the wildcard auction. Both self-fetch
/// their state and render NOTHING unless the auction is enabled, so neither
/// teases a seat that can't actually be bid on (the whole feature is gated off
/// until config/tournament.enabled AND wildcardAuctionEnabled are both true).
///
/// They are deliberately quiet - a persistent line in the two places a player
/// already looks (the Main Stage hub, and the points/Rewards screen) - so the
/// earn-your-way-on path is found, never shoved.
///
///  - [WildcardStrip]: a slim gold-outlined row for the Main Stage hub.
///  - [WildcardSpendTile]: a card matching the Rewards redeem list.

/// Shared loader: fetches auction state and reopens the bid sheet, re-fetching
/// on return. Subclasses render their own chrome from [_state].
abstract class _WildcardEntryState<T extends StatefulWidget> extends State<T> {
  final _service = WildcardAuctionService();
  WildcardAuctionState? _state;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final s = await _service.state();
    if (mounted) setState(() => _state = s);
  }

  Future<void> _open() async {
    await showWildcardBidSheet(context, initial: _state);
    await _load();
  }

  bool get _show => _state != null && _state!.enabled;
}

/// The Main Stage hub strip. Sits under the countdown header; one tap opens the
/// bid sheet.
class WildcardStrip extends StatefulWidget {
  const WildcardStrip({super.key});

  @override
  State<WildcardStrip> createState() => _WildcardStripState();
}

class _WildcardStripState extends _WildcardEntryState<WildcardStrip> {
  @override
  Widget build(BuildContext context) {
    if (!_show) return const SizedBox.shrink();
    final s = _state!;
    final gold = context.palette.reward;
    final text = Theme.of(context).textTheme;
    final hasBid = s.hasBid;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: _open,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              color: Colors.white.withValues(alpha: 0.03),
              border: Border.all(color: gold.withValues(alpha: 0.4)),
            ),
            child: Row(
              children: [
                Text('🎟️', style: text.titleMedium),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Wildcard seat',
                        style: text.titleSmall?.copyWith(
                          fontWeight: FontWeight.w900,
                          color: gold,
                        ),
                      ),
                      Text(
                        hasBid
                            ? 'Your bid: ${s.yourBid} pts - highest wins'
                            : 'One spot, highest bidder takes the stage',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: text.bodySmall?.copyWith(
                          color: Colors.white.withValues(alpha: 0.75),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: gold,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    hasBid ? 'Raise' : 'Bid',
                    style: const TextStyle(
                      color: Colors.black,
                      fontWeight: FontWeight.w900,
                    ),
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

/// The Rewards-screen tile. Matches the day-pass / clip redeem cards so the
/// wildcard reads as one more thing points buy - the "wait, points get me onto
/// the show?" discovery.
class WildcardSpendTile extends StatefulWidget {
  const WildcardSpendTile({super.key});

  @override
  State<WildcardSpendTile> createState() => _WildcardSpendTileState();
}

class _WildcardSpendTileState extends _WildcardEntryState<WildcardSpendTile> {
  @override
  Widget build(BuildContext context) {
    if (!_show) return const SizedBox.shrink();
    final s = _state!;
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final gold = context.palette.currency;
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: scheme.surfaceContainer,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: scheme.outlineVariant),
        ),
        child: Row(
          children: [
            const Text('🎟️', style: TextStyle(fontSize: 26)),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        'Main Stage wildcard',
                        style: text.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        s.hasBid ? 'bid ${s.yourBid}' : 'bid',
                        style: text.labelMedium?.copyWith(
                          color: gold,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(
                    'One seat on the show, won by bid. Highest bidder takes it.',
                    style: text.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                      height: 1.2,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            FilledButton(
              onPressed: _open,
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 8,
                ),
                visualDensity: VisualDensity.compact,
              ),
              child: Text(s.hasBid ? 'Raise' : 'Bid'),
            ),
          ],
        ),
      ),
    );
  }
}
