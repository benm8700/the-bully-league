import 'package:flutter/material.dart';

import '../../core/emoji_ratings.dart';
import '../../core/services/emoji_scrub_service.dart';

/// Spend points to clean up your NEGATIVE emoji ratings (🥱/💩). The rows are
/// built from [kRemovableEmojiRatings] (derived from the `positive` flag), so a
/// future negative emoji shows up here automatically. The server is the
/// authority; this sheet just reflects what it returns.
class EmojiScrubSheet extends StatefulWidget {
  const EmojiScrubSheet({super.key});

  /// Opens the sheet. The caller should refresh the profile afterwards (one
  /// cheap read) so the Crowd-read card reflects any cleanup.
  static Future<void> show(BuildContext context) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF17151C),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => const EmojiScrubSheet(),
    );
  }

  @override
  State<EmojiScrubSheet> createState() => _EmojiScrubSheetState();
}

class _EmojiScrubSheetState extends State<EmojiScrubSheet> {
  /// How many we try to remove per tap (clamped server-side by count, the
  /// daily cap and the balance). One at a time: at 50 points each, removing a
  /// bad rating is a deliberate, costly choice - which keeps the public counts
  /// honest rather than cheaply buyable.
  static const _chunk = 1;

  Map<String, dynamic>? _state;
  String? _error;
  bool _loading = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final s = await EmojiScrubService.getState();
      if (mounted) {
        setState(() {
          _state = s;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _error = "Couldn't load this right now.";
          _loading = false;
        });
      }
    }
  }

  int _price() => (_state?['price'] as num?)?.toInt() ?? 0;
  int _balance() => (_state?['balance'] as num?)?.toInt() ?? 0;
  int _dailyRemaining() => (_state?['dailyRemaining'] as num?)?.toInt() ?? 0;
  int _countOf(String key) =>
      ((_state?['counts'] as Map?)?[key] as num?)?.toInt() ?? 0;

  /// How many a tap would actually remove for [key], given every ceiling.
  int _removable(String key) {
    final price = _price();
    if (price <= 0) return 0;
    final affordable = _balance() ~/ price;
    return [_chunk, _countOf(key), _dailyRemaining(), affordable]
        .reduce((a, b) => a < b ? a : b)
        .clamp(0, 1 << 30);
  }

  Future<void> _scrub(String key) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final r = await EmojiScrubService.scrub(emojiKey: key, count: _chunk);
      final scrubbed = (r['scrubbed'] as num?)?.toInt() ?? 0;
      if (scrubbed > 0) {
        setState(() {
          final counts =
              Map<String, dynamic>.from(_state?['counts'] as Map? ?? {});
          counts[key] = (r['newCount'] as num?)?.toInt() ?? _countOf(key);
          _state = {
            ...?_state,
            'counts': counts,
            'balance': (r['balance'] as num?)?.toInt() ?? _balance(),
            'dailyRemaining':
                (r['dailyRemaining'] as num?)?.toInt() ?? _dailyRemaining(),
          };
        });
        if (mounted) {
          final emoji = emojiCharFor(key);
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('Cleaned up $scrubbed $emoji'),
            duration: const Duration(seconds: 2),
          ));
        }
      }
    } on Exception catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(_friendly(e)),
          duration: const Duration(seconds: 3),
        ));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _friendly(Object e) {
    final s = e.toString();
    // FirebaseFunctionsException puts the server message after the code.
    final i = s.indexOf(']');
    final msg = i >= 0 && i + 1 < s.length ? s.substring(i + 1).trim() : s;
    return msg.isEmpty ? "Couldn't clean that up." : msg;
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
            20, 16, 20, 16 + MediaQuery.of(context).viewInsets.bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.only(bottom: 14),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Text('Clean up your ratings',
                style: text.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
            const SizedBox(height: 4),
            Text(
              'Spend points to shave down the ratings you would rather not '
              'wear. Positives stay - you earn those.',
              style: text.bodySmall
                  ?.copyWith(color: Colors.white.withValues(alpha: 0.6)),
            ),
            const SizedBox(height: 16),
            _body(context),
          ],
        ),
      ),
    );
  }

  Widget _body(BuildContext context) {
    final text = Theme.of(context).textTheme;
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (_error != null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Text(_error!, style: text.bodyMedium),
      );
    }
    if (_state?['enabled'] == false) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Text("Cleaning up ratings isn't available right now.",
            style: text.bodyMedium),
      );
    }

    final rows = <Widget>[];
    for (final r in kRemovableEmojiRatings) {
      final count = _countOf(r.key);
      if (count <= 0) continue;
      rows.add(_emojiRow(context, r));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Balance + daily remaining.
        Row(
          children: [
            Icon(Icons.toll, size: 16, color: const Color(0xFFF4C838)),
            const SizedBox(width: 6),
            Text('${_balance()} points',
                style: text.bodyMedium?.copyWith(fontWeight: FontWeight.w700)),
            const Spacer(),
            Text('${_dailyRemaining()} left to clean today',
                style: text.bodySmall
                    ?.copyWith(color: Colors.white.withValues(alpha: 0.55))),
          ],
        ),
        const SizedBox(height: 14),
        if (rows.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text('Nothing to clean up - your record is clean.',
                style: text.bodyMedium
                    ?.copyWith(color: Colors.white.withValues(alpha: 0.7))),
          )
        else
          ...rows,
      ],
    );
  }

  Widget _emojiRow(BuildContext context, EmojiRating r) {
    final text = Theme.of(context).textTheme;
    final count = _countOf(r.key);
    final removable = _removable(r.key);
    final price = _price();
    final cost = removable * price;
    final canScrub = removable > 0 && !_busy;

    String label;
    if (removable > 0) {
      label = 'Remove $removable · $cost pts';
    } else if (_balance() < price) {
      label = 'Not enough points';
    } else if (_dailyRemaining() <= 0) {
      label = 'Daily limit reached';
    } else {
      label = 'Remove';
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          Text(r.emoji, style: const TextStyle(fontSize: 26)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(r.label,
                    style:
                        text.bodyMedium?.copyWith(fontWeight: FontWeight.w700)),
                Text('You have $count',
                    style: text.bodySmall
                        ?.copyWith(color: Colors.white.withValues(alpha: 0.55))),
              ],
            ),
          ),
          OutlinedButton(
            onPressed: canScrub ? () => _scrub(r.key) : null,
            style: OutlinedButton.styleFrom(
              side: BorderSide(color: Colors.white.withValues(alpha: 0.25)),
              foregroundColor: Colors.white,
            ),
            child: Text(label),
          ),
        ],
      ),
    );
  }
}
