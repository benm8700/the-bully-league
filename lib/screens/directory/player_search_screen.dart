import 'dart:async';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';

/// Finding another player by name.
///
/// Every safety rule lives on the server (functions/playerDirectory.js) -
/// opt-out, two-way blocking, banned accounts, and the fact that a result
/// carries a name, a face and a rank and nothing else. None of that can be
/// enforced from here, so this screen deliberately does no filtering of
/// its own: it renders exactly what it is given.
class PlayerSearchScreen extends StatefulWidget {
  const PlayerSearchScreen({super.key});

  @override
  State<PlayerSearchScreen> createState() => _PlayerSearchScreenState();
}

/// The per-row challenge control.
///
/// Becomes inert once a challenge has been sent rather than staying
/// tappable: the server caps outstanding challenges at three from one
/// sender, so a repeat tap would spend that allowance on the same person
/// and then start failing for no visible reason.
class _ChallengeButton extends StatelessWidget {
  const _ChallengeButton({required this.state, required this.onPressed});

  final String? state;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    if (state == 'sending') {
      return const SizedBox(
        height: 20,
        width: 20,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    }
    if (state == 'sent') {
      return const Icon(Icons.check);
    }
    return TextButton(onPressed: onPressed, child: const Text('Challenge'));
  }
}

class _PlayerSearchScreenState extends State<PlayerSearchScreen> {
  final _controller = TextEditingController();
  Timer? _debounce;
  bool _searching = false;
  String? _message;
  List<Map<String, dynamic>> _results = const [];

  /// Per-row challenge state, keyed by username: 'sending', 'sent', or
  /// the server's own error message.
  ///
  /// Kept per row rather than as one screen-wide flag because the
  /// results are a list of people and a single banner could not say
  /// WHICH of them it was about.
  final Map<String, String> _challengeState = {};

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  /// Debounced, so typing a name is one search rather than one per
  /// keystroke - each is a function call and a Firestore query.
  void _onChanged(String value) {
    _debounce?.cancel();
    if (value.trim().length < 2) {
      setState(() {
        _results = const [];
        _message = null;
      });
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 350), () => _search(value));
  }

  Future<void> _search(String query) async {
    setState(() {
      _searching = true;
      _message = null;
    });
    try {
      final result = await FirebaseFunctions.instance
          .httpsCallable('searchPlayers')
          .call<Map<String, dynamic>>({'query': query.trim()});
      if (!mounted) return;
      final results = ((result.data['results'] as List?) ?? const [])
          .map((e) => (e as Map).cast<String, dynamic>())
          .toList();
      setState(() {
        _results = results;
        _searching = false;
        _message = results.isEmpty ? 'Nobody by that name.' : null;
      });
    } on FirebaseFunctionsException catch (e) {
      if (!mounted) return;
      setState(() {
        _searching = false;
        _results = const [];
        _message = e.message ?? 'Search is unavailable right now.';
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _searching = false;
        _message = 'Search is unavailable right now.';
      });
    }
  }

  /// Challenges a specific player, by name.
  ///
  /// THIS IS DELIBERATELY UNRATED. Choosing your own opponent is
  /// exactly the collusion vector the random pairing exists to prevent,
  /// so a friend battle moves no rating and pays no points - it is
  /// recorded, judged and clippable instead. The button says so, because
  /// somebody who found a specific person and challenged them would
  /// otherwise reasonably assume it counted.
  Future<void> _challenge(String username) async {
    setState(() => _challengeState[username] = 'sending');
    try {
      await FirebaseFunctions.instance
          .httpsCallable('challengeFriend')
          .call<Map<String, dynamic>>({'username': username});
      if (!mounted) return;
      setState(() => _challengeState[username] = 'sent');
    } on FirebaseFunctionsException catch (e) {
      if (!mounted) return;
      // The server's message verbatim. It is the one that knows whether
      // this was a block, a ban, an unknown name or the outstanding cap,
      // and it phrases a block identically to a missing player ON
      // PURPOSE - saying otherwise here would leak exactly what blocking
      // is silent in order to hide.
      setState(() =>
          _challengeState[username] = e.message ?? 'Could not send that.');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Find a Player')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: TextField(
              controller: _controller,
              autofocus: true,
              textInputAction: TextInputAction.search,
              decoration: const InputDecoration(
                labelText: 'Username',
                prefixIcon: Icon(Icons.search),
                // Says the requirement up front rather than returning an
                // error after the fact.
                helperText: 'At least 2 characters',
              ),
              onChanged: _onChanged,
              onSubmitted: _search,
            ),
          ),
          if (_searching) const LinearProgressIndicator(minHeight: 2),
          if (_message != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
              child: Text(_message!,
                  style: Theme.of(context).textTheme.bodySmall),
            ),
          Expanded(
            child: ListView.builder(
              itemCount: _results.length,
              itemBuilder: (context, i) {
                final r = _results[i];
                final photo = r['photoUrl'] as String?;
                final username = r['username'] as String? ?? 'Unknown';
                final state = _challengeState[username];
                return ListTile(
                  leading: CircleAvatar(
                    backgroundImage:
                        photo != null ? NetworkImage(photo) : null,
                    child: photo == null ? const Icon(Icons.person) : null,
                  ),
                  title: Text(username),
                  // The rank, plus whatever happened when you challenged
                  // them. A failure belongs on the row it came from, not
                  // in a snackbar that outlives the row it described.
                  subtitle: Text(
                    state == null || state == 'sending'
                        ? (r['rankTitle'] as String? ?? '')
                        : state == 'sent'
                            ? 'Challenged. They have an hour to answer.'
                            : state,
                    style: state != null && state != 'sending' &&
                            state != 'sent'
                        ? TextStyle(
                            color: Theme.of(context).colorScheme.error)
                        : null,
                  ),
                  trailing: _ChallengeButton(
                    state: state,
                    onPressed: () => _challenge(username),
                  ),
                );
              },
            ),
          ),
          // Said here, on the screen that makes people findable, rather
          // than buried in settings - somebody who is uncomfortable being
          // searchable is most likely to realise it at this moment.
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
            child: Text(
              'Challenges are unrated - no rating, no points. They are still recorded, judged and clippable.\n\nYou can remove yourself from search on your profile.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}
