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

class _PlayerSearchScreenState extends State<PlayerSearchScreen> {
  final _controller = TextEditingController();
  Timer? _debounce;
  bool _searching = false;
  String? _message;
  List<Map<String, dynamic>> _results = const [];

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
                return ListTile(
                  leading: CircleAvatar(
                    backgroundImage:
                        photo != null ? NetworkImage(photo) : null,
                    child: photo == null ? const Icon(Icons.person) : null,
                  ),
                  title: Text(r['username'] as String? ?? 'Unknown'),
                  subtitle: Text(r['rankTitle'] as String? ?? ''),
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
              'You can remove yourself from search on your profile.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}
