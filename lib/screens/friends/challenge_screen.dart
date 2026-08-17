import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';

import '../match/pre_match_screen.dart';
import '../match/recording_consent_screen.dart';

/// Challenge someone by name, and answer challenges sent to you.
///
/// THIS IS THE ONLY PATH THAT WORKS WITH FIVE USERS. Every other way into
/// a match needs a stranger to be awake and in the app at the same moment,
/// which is exactly what a private beta cannot supply. The beta group is a
/// handful of friends - the people who most want to battle each other on
/// purpose.
///
/// BY USERNAME, NOT THROUGH THE DIRECTORY, and that is what keeps this
/// free at every tier: the searchable player directory is a subscriber
/// feature, but knowing your friend's name is not. CLAUDE.md is explicit
/// that friend battles must not be paywalled.
class ChallengeScreen extends StatefulWidget {
  const ChallengeScreen({super.key});

  @override
  State<ChallengeScreen> createState() => _ChallengeScreenState();
}

class _ChallengeScreenState extends State<ChallengeScreen> {
  final _controller = TextEditingController();
  List<Map<String, dynamic>> _incoming = const [];
  List<Map<String, dynamic>> _outgoing = const [];
  bool _loading = true;
  bool _busy = false;
  String? _error;
  String? _sent;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final r = await FirebaseFunctions.instance
          .httpsCallable('getMyChallenges')
          .call<Map<String, dynamic>>();
      if (!mounted) return;
      setState(() {
        _incoming = ((r.data['incoming'] as List?) ?? const [])
            .map((e) => (e as Map).cast<String, dynamic>())
            .toList();
        _outgoing = ((r.data['outgoing'] as List?) ?? const [])
            .map((e) => (e as Map).cast<String, dynamic>())
            .toList();
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _send() async {
    final name = _controller.text.trim();
    if (name.isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
      _sent = null;
    });
    try {
      await FirebaseFunctions.instance
          .httpsCallable('challengeFriend')
          .call<Map<String, dynamic>>({'username': name});
      if (!mounted) return;
      _controller.clear();
      setState(() {
        _busy = false;
        _sent = "Challenge sent to $name. They have an hour to answer.";
      });
      await _load();
    } on FirebaseFunctionsException catch (e) {
      if (!mounted) return;
      // The server's message is shown verbatim: it is the one that knows
      // whether this was an unknown name, a block, or the outstanding cap,
      // and it phrases a block indistinguishably from a missing player on
      // purpose.
      setState(() {
        _busy = false;
        _error = e.message ?? 'Could not send that.';
      });
    }
  }

  Future<void> _respond(String challengeId, bool accept) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final r = await FirebaseFunctions.instance
          .httpsCallable('respondToChallenge')
          .call<Map<String, dynamic>>({
        'challengeId': challengeId,
        'accept': accept,
      });
      if (!mounted) return;
      setState(() => _busy = false);
      if (accept && r.data['matchId'] != null) {
        await startChallengeMatch(context, r.data['matchId'] as String);
      } else {
        await _load();
      }
    } on FirebaseFunctionsException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e.message ?? 'Could not answer that.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Battle a friend')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(24),
              children: [
                if (_incoming.isNotEmpty) ...[
                  Text('Waiting for you', style: text.titleMedium),
                  const SizedBox(height: 8),
                  ..._incoming.map((c) => Card(
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Text('${c['fromUsername']} challenged you',
                                  style: text.titleSmall),
                              const SizedBox(height: 10),
                              Row(
                                children: [
                                  Expanded(
                                    child: FilledButton(
                                      onPressed: _busy
                                          ? null
                                          : () => _respond(
                                              c['challengeId'] as String, true),
                                      child: const Text('Accept'),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  TextButton(
                                    onPressed: _busy
                                        ? null
                                        : () => _respond(
                                            c['challengeId'] as String, false),
                                    child: const Text('No thanks'),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      )),
                  const SizedBox(height: 24),
                ],
                Text('Challenge someone', style: text.titleMedium),
                const SizedBox(height: 4),
                Text(
                  // States the two things people are most likely to get
                  // wrong about this mode, before they play rather than
                  // after: it does not count, and it is still filmed.
                  'Type their username. It does not affect your rank - but '
                  'it is still recorded, judged by the crowd, and can be '
                  'clipped.',
                  style: text.bodySmall,
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _controller,
                  decoration: const InputDecoration(
                    labelText: 'Their username',
                    border: OutlineInputBorder(),
                  ),
                  onSubmitted: (_) => _send(),
                ),
                const SizedBox(height: 12),
                FilledButton(
                  onPressed: _busy ? null : _send,
                  child: const Text('Send challenge'),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(_error!,
                      style: text.bodySmall
                          ?.copyWith(color: Theme.of(context).colorScheme.error)),
                ],
                if (_sent != null) ...[
                  const SizedBox(height: 12),
                  Text(_sent!, style: text.bodySmall),
                ],
                if (_outgoing.isNotEmpty) ...[
                  const SizedBox(height: 24),
                  Text('Sent', style: text.titleMedium),
                  const SizedBox(height: 8),
                  ..._outgoing.map((c) => ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.hourglass_empty, size: 18),
                        title: Text('Waiting on ${c['toUsername']}'),
                      )),
                ],
              ],
            ),
    );
  }
}

/// Takes an accepted challenge into the normal match flow.
///
/// Routed through recording consent and the camera check exactly like any
/// other battle - a friend battle IS recorded and clip-eligible, so
/// consent is not optional here just because you know the person.
Future<void> startChallengeMatch(BuildContext context, String matchId) async {
  final consented = await Navigator.of(context).push<bool>(
        MaterialPageRoute(builder: (_) => const RecordingConsentScreen()),
      ) ??
      false;
  if (!consented || !context.mounted) return;
  await Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => PreMatchScreen(mode: 'friend', challengeMatchId: matchId),
    ),
  );
}
