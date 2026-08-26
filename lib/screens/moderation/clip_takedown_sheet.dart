import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';


/// Lets a player object to their own battle footage being public.
///
/// TWO CHANNELS, PRESENTED VERY DIFFERENTLY, because they are different
/// requests. "I'd rather this wasn't posted" is a preference, so it has a
/// deadline and a monthly allowance and both are stated openly. "This is
/// hurting me" is not a preference, and it is always available with no
/// deadline, no allowance and nothing in the way.
///
/// THE MOST IMPORTANT LINE ON THIS SCREEN is that removing a clip does not
/// change the result. Most requests to delete a battle are really attempts
/// to erase a loss, and saying plainly that the loss stands removes the
/// motive without obstructing anyone - which is far better than making the
/// process deliberately awkward, since designing obstruction reads terribly
/// in hindsight and does not stop a determined person anyway.
class ClipTakedownSheet extends StatefulWidget {
  const ClipTakedownSheet({super.key, required this.matchId});

  final String matchId;

  static Future<void> show(BuildContext context, String matchId) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => ClipTakedownSheet(matchId: matchId),
    );
  }

  @override
  State<ClipTakedownSheet> createState() => _ClipTakedownSheetState();
}

const _harmReasons = {
  'harassment': 'I\'m being harassed over this',
  'doxxing': 'It exposes private information',
  'false_claim': 'It states something untrue about me as fact',
  'brigading': 'People are piling on me because of it',
  'other': 'Something else',
};

class _ClipTakedownSheetState extends State<ClipTakedownSheet> {
  Map<String, dynamic>? _options;
  String? _error;
  bool _working = false;
  bool _done = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final result = await FirebaseFunctions.instance
          .httpsCallable('getTakedownOptions')
          .call<Map<String, dynamic>>({'matchId': widget.matchId});
      if (!mounted) return;
      setState(() => _options = result.data);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '$e');
    }
  }

  Future<void> _request(String channel, {String? reason}) async {
    setState(() {
      _working = true;
      _error = null;
    });
    try {
      await FirebaseFunctions.instance.httpsCallable('requestTakedown').call({
        'matchId': widget.matchId,
        'channel': channel,
        // ignore: use_null_aware_elements
        if (reason != null) 'reason': reason,
      });
      if (!mounted) return;
      setState(() => _done = true);
    } on FirebaseFunctionsException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message ?? e.code);
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Scrollable: the harm options make this taller than a small screen,
    // and this is the last place in the app where content should be cut
    // off - someone reaching for it is already unhappy.
    return SingleChildScrollView(
      padding: EdgeInsets.only(
        left: 24,
        right: 24,
        top: 24,
        bottom: MediaQuery.of(context).viewInsets.bottom + 24,
      ),
      child: _body(context),
    );
  }

  Widget _body(BuildContext context) {
    if (_done) return _confirmation(context);
    if (_options == null && _error == null) {
      return const SizedBox(
        height: 120,
        child: Center(child: CircularProgressIndicator()),
      );
    }

    final o = _options ?? const {};
    final alreadyObjected = o['alreadyObjected'] == true;
    final preferenceOpen = o['preferenceOpen'] == true;
    final remaining = (o['preferenceRemaining'] as num?)?.toInt() ?? 0;
    final cap = (o['preferenceCap'] as num?)?.toInt() ?? 2;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('This battle', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 8),
        // The line that does the real work.
        const Text(
          'Taking the clip down does not change the result. The match, the '
          'rating and the win or loss all stand either way.',
          style: TextStyle(fontSize: 13),
        ),
        const SizedBox(height: 20),

        if (alreadyObjected)
          const Text(
            'You have already asked for this one not to be posted. It will '
            'not go public.',
            style: TextStyle(fontWeight: FontWeight.bold),
          )
        else ...[
          if (preferenceOpen && remaining > 0) ...[
            FilledButton.tonal(
              onPressed: _working ? null : () => _request('preference'),
              child: const Text('I\'d rather this wasn\'t posted'),
            ),
            const SizedBox(height: 6),
            Text(
              '$remaining of $cap left this month. You can do this until '
              'voting closes on this battle.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ] else
            Text(
              preferenceOpen
                  ? 'You have used your $cap opt-outs this month.'
                  : 'Voting has closed on this battle, so the opt-out window '
                      'has passed.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          const SizedBox(height: 20),
          const Divider(),
          const SizedBox(height: 8),
          // Deliberately never gated, capped or deadlined - and said so, so
          // someone who has run out of opt-outs knows this is still here.
          Text('Is this clip causing you harm?',
              style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 4),
          const Text(
            'No deadline and no limit on these. The clip comes down straight '
            'away and a human reviews it afterwards.',
            style: TextStyle(fontSize: 12),
          ),
          const SizedBox(height: 12),
          for (final entry in _harmReasons.entries)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: OutlinedButton(
                onPressed: _working
                    ? null
                    : () => _request('harm', reason: entry.key),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(entry.value, textAlign: TextAlign.left),
                ),
              ),
            ),
        ],

        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(_error!, style: const TextStyle(color: Color(0xFFE05252), fontSize: 12)),
        ],
      ],
    );
  }

  Widget _confirmation(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.check_circle_outline, size: 40),
        const SizedBox(height: 12),
        Text('Done', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 8),
        const Text(
          'This battle will not be posted publicly, and any clip already out '
          'there has been taken down. The match result is unchanged.',
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 20),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}
