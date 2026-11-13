import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/services/wildcard_auction_service.dart';
import '../../theme/app_theme.dart';
import '../../widgets/neon_dialog.dart';

/// Open the wildcard bid sheet. The sheet handles the bid and shows its own
/// feedback; openers should simply re-fetch their auction state on return (the
/// balance and current bid may have changed).
///
/// Pass [initial] when the opener already has fresh state (the hub strip and
/// the rewards tile both do), so the sheet opens populated with no flash; it
/// still re-fetches after a bid to show the new balance and bid.
Future<void> showWildcardBidSheet(
  BuildContext context, {
  WildcardAuctionState? initial,
}) {
  return showNeonSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: const Color(0xFF15110A),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) => _WildcardBidSheet(initial: initial),
  );
}

class _WildcardBidSheet extends StatefulWidget {
  const _WildcardBidSheet({this.initial});

  final WildcardAuctionState? initial;

  @override
  State<_WildcardBidSheet> createState() => _WildcardBidSheetState();
}

class _WildcardBidSheetState extends State<_WildcardBidSheet> {
  final _service = WildcardAuctionService();
  final _controller = TextEditingController();

  WildcardAuctionState? _state;
  bool _loading = true;
  bool _submitting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _state = widget.initial;
    _loading = widget.initial == null;
    _prefill();
    // Always re-fetch so the sheet reflects the live balance/bid even when an
    // initial state was handed in.
    _refresh();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _prefill() {
    final s = _state;
    if (s == null) return;
    final suggested = s.yourBid ?? s.bidFloor;
    if (suggested > 0 && _controller.text.isEmpty) {
      _controller.text = '$suggested';
    }
  }

  Future<void> _refresh() async {
    final fresh = await _service.state();
    if (!mounted) return;
    setState(() {
      if (fresh != null) _state = fresh;
      _loading = false;
    });
    _prefill();
  }

  Future<void> _submit() async {
    final s = _state;
    if (s == null) return;
    final amount = int.tryParse(_controller.text.trim());
    if (amount == null || amount < s.bidFloor) {
      setState(() => _error = 'Enter a bid of at least ${s.bidFloor} points.');
      return;
    }
    if (amount > s.balance) {
      setState(
        () => _error = 'You only have ${s.balance} points to back that bid.',
      );
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final result = await _service.placeBid(amount);
      if (!mounted) return;
      final msg = result.feeCharged
          ? "You're in. Highest bid Thursday takes the seat."
          : 'Bid raised to ${result.amount}. Highest bid Thursday wins.';
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
      await _refresh();
    } on Object catch (e) {
      if (!mounted) return;
      setState(() => _error = _friendly(e));
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  String _friendly(Object e) {
    final s = e.toString();
    final i = s.indexOf('] ');
    return i >= 0 ? s.substring(i + 2) : 'Could not place your bid.';
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final gold = context.palette.reward;
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    final s = _state;

    return Padding(
      padding: EdgeInsets.fromLTRB(20, 16, 20, 20 + bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.white24,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Text('🎟️', style: text.headlineSmall),
              const SizedBox(width: 10),
              Text(
                'The Wildcard Seat',
                style: text.titleLarge?.copyWith(
                  fontWeight: FontWeight.w900,
                  color: gold,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            'Three finalists earn their spot by climbing the ranks. The fourth '
            'is the wildcard - and it is bought. The single highest bidder '
            'takes the seat and steps onto the Main Stage. You still have to '
            'out-roast everyone once you are up there - the seat buys a shot, '
            'not a win.',
            style: text.bodyMedium?.copyWith(
              height: 1.4,
              color: Colors.white.withValues(alpha: 0.82),
            ),
          ),
          const SizedBox(height: 20),
          if (_loading && s == null)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (s == null || !s.enabled)
            _closedBody(text)
          else if (!s.eligible)
            _ineligibleBody(text, s)
          else
            _bidBody(text, gold, s),
        ],
      ),
    );
  }

  Widget _closedBody(TextTheme text) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Text(
      'Bidding is closed right now. The wildcard opens each week alongside '
      'the race to the Main Stage.',
      style: text.bodyMedium?.copyWith(
        color: Colors.white.withValues(alpha: 0.7),
        height: 1.4,
      ),
    ),
  );

  Widget _ineligibleBody(TextTheme text, WildcardAuctionState s) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
      ),
      child: Row(
        children: [
          const Icon(Icons.lock_outline, color: Colors.white54, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              s.message ?? 'You cannot bid on the wildcard yet.',
              style: text.bodyMedium?.copyWith(
                color: Colors.white.withValues(alpha: 0.85),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _bidBody(TextTheme text, Color gold, WildcardAuctionState s) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (s.hasBid)
          _statusRow(
            text,
            gold,
            'Your bid',
            '${s.yourBid} pts - highest Thursday wins',
          )
        else
          _statusRow(
            text,
            gold,
            'Entry fee',
            '${s.entryFee} pts, charged once',
          ),
        const SizedBox(height: 6),
        _statusRow(text, Colors.white70, 'Your points', '${s.balance}'),
        const SizedBox(height: 18),
        TextField(
          controller: _controller,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          style: text.titleMedium?.copyWith(fontWeight: FontWeight.w800),
          decoration: InputDecoration(
            labelText: s.hasBid ? 'Raise your bid to' : 'Your bid',
            helperText: 'At least ${s.bidFloor} points',
            suffixText: 'pts',
            border: const OutlineInputBorder(),
          ),
        ),
        if (_error != null) ...[
          const SizedBox(height: 10),
          Text(
            _error!,
            style: text.bodySmall?.copyWith(color: context.palette.live),
          ),
        ],
        const SizedBox(height: 16),
        SizedBox(
          width: double.infinity,
          height: 52,
          child: FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: gold,
              foregroundColor: Colors.black,
            ),
            onPressed: _submitting ? null : _submit,
            child: _submitting
                ? const SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(
                    s.hasBid ? 'Raise bid' : 'Place bid',
                    style: const TextStyle(fontWeight: FontWeight.w900),
                  ),
          ),
        ),
        const SizedBox(height: 10),
        Text(
          'Only the winner pays their bid. Lose, and you keep your points - the '
          'entry fee is the only cost.',
          style: text.bodySmall?.copyWith(
            color: Colors.white.withValues(alpha: 0.55),
            height: 1.35,
          ),
        ),
      ],
    );
  }

  Widget _statusRow(TextTheme text, Color accent, String label, String value) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: text.bodyMedium?.copyWith(
            color: Colors.white.withValues(alpha: 0.6),
          ),
        ),
        const SizedBox(width: 12),
        Flexible(
          child: Text(
            value,
            textAlign: TextAlign.end,
            style: text.bodyMedium?.copyWith(
              color: accent,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
      ],
    );
  }
}
