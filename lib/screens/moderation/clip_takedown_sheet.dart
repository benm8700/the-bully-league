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

/// Narrowed to the serious grounds we are actually obligated to act on -
/// harassment beyond the roast, doxxing, a false factual claim, and
/// sexual/threatening/minor content. The vaguer "brigading" and catch-all
/// "other" were removed on purpose: a joke at your expense is not a takedown
/// ground, and the general report button (on every clip) remains the broad
/// Apple-1.2 flagging mechanism.
const _harmGrounds = {
  'harassment': 'It targets or harasses me, beyond the roast itself',
  'private_info': 'It exposes private information about me (doxxing)',
  'false_claim': 'It states something untrue about me as a fact',
  'explicit_or_threat': 'It is sexual, threatening, or involves a minor',
};

class _ClipTakedownSheetState extends State<ClipTakedownSheet> {
  Map<String, dynamic>? _options;
  String? _error;
  bool _working = false;
  bool _done = false;

  /// 'gate' (is this harming you?) -> 'reminder' (it's comedy) -> 'grounds'
  /// (which of the serious grounds). A speed bump, deliberately NOT an
  /// obstruction: it never blocks a genuine harm report, it just makes sure
  /// the casual "delete my loss" request stops at the first screen.
  String _step = 'gate';

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

    if (alreadyObjected) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('This clip', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          const Text(
            'You have already asked for this one not to be posted. It will '
            'not go public.',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 20),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Close'),
            ),
          ),
        ],
      );
    }

    final Widget step = switch (_step) {
      'reminder' => _reminderStep(context),
      'grounds' => _groundsStep(context),
      _ => _gateStep(context, preferenceOpen, remaining),
    };

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        step,
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(_error!,
              style: const TextStyle(color: Color(0xFFE05252), fontSize: 12)),
        ],
      ],
    );
  }

  /// Step 1 - the gate. Nothing about the harm channel shows until they say
  /// yes, so a casual "delete my loss" impulse stops here.
  Widget _gateStep(
      BuildContext context, bool preferenceOpen, int remaining) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Is this clip causing you harm?',
            style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 10),
        // The line that does the real work: most delete requests are really
        // about a loss, and this removes the motive without obstruction.
        const Text(
          'Taking a clip down does not change the result - the match, the '
          'rating and the win or loss all stand. And getting roasted, even '
          'brutally, is the whole point here. So this is only for clips that '
          'cross into real harm.',
          style: TextStyle(fontSize: 13),
        ),
        const SizedBox(height: 20),
        // All buttons in this flow are PLAIN and neutral, never a highlighted
        // CTA - a prominent pink "report" button reads as the app inviting
        // reports, which is the opposite of the intent here.
        _plainAction(context, 'Yes, it is causing me harm',
            _working ? null : () => setState(() => _step = 'reminder')),
        const SizedBox(height: 8),
        _plainCancel(context, 'No, never mind',
            () => Navigator.of(context).pop()),
        // The pre-publication opt-out survives, but quietly - a small
        // secondary link, only while the clip has not gone public and the
        // monthly allowance is left. Not promoted (clips are distribution).
        if (preferenceOpen && remaining > 0)
          _plainCancel(context, "I'd just rather it wasn't posted",
              _working ? null : () => _request('preference')),
      ],
    );
  }

  /// A plain, un-highlighted action button (outlined, neutral colour) - not a
  /// filled brand CTA, so the reporting flow never looks like an invitation.
  Widget _plainAction(
      BuildContext context, String label, VoidCallback? onPressed) {
    final scheme = Theme.of(context).colorScheme;
    return OutlinedButton(
      style: OutlinedButton.styleFrom(
        foregroundColor: scheme.onSurface,
        side: BorderSide(color: scheme.outlineVariant),
      ),
      onPressed: onPressed,
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(label, textAlign: TextAlign.left),
      ),
    );
  }

  /// A muted text button for cancel / secondary actions.
  Widget _plainCancel(
      BuildContext context, String label, VoidCallback? onPressed) {
    return TextButton(
      style: TextButton.styleFrom(
        foregroundColor: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
      onPressed: onPressed,
      child: Text(label),
    );
  }

  /// Step 2 - the reminder. A speed bump that says out loud what the app is,
  /// so the bar for "harm" is set before any grounds are shown.
  Widget _reminderStep(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('A quick reminder', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 10),
        const Text(
          'The Bully League is a comedy platform. Making fun of people - even '
          'brutally - is the entire purpose here, and a joke at your expense, '
          'however harsh, is not harm. We only take a clip down when it '
          'genuinely crosses the line.',
          style: TextStyle(fontSize: 13),
        ),
        const SizedBox(height: 20),
        _plainAction(context, 'I understand - continue',
            _working ? null : () => setState(() => _step = 'grounds')),
        const SizedBox(height: 8),
        _plainCancel(context, 'Never mind', () => Navigator.of(context).pop()),
      ],
    );
  }

  /// Step 3 - the narrowed grounds. Selecting one files the harm takedown:
  /// the clip comes down immediately and a person reviews it after.
  Widget _groundsStep(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Does the clip do one of these?',
            style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 6),
        const Text(
          'Pick the one that fits. The clip comes down straight away and a '
          'person reviews it afterwards.',
          style: TextStyle(fontSize: 12),
        ),
        const SizedBox(height: 14),
        for (final entry in _harmGrounds.entries)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: _plainAction(context, entry.value,
                _working ? null : () => _request('harm', reason: entry.key)),
          ),
        const SizedBox(height: 4),
        _plainCancel(context, 'Back', () => setState(() => _step = 'gate')),
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
