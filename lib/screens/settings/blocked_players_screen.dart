import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';

/// The people this player has blocked, and the way to undo it.
///
/// Blocking without this screen would be a ONE-WAY DOOR: matchmaking and
/// the player directory both honour the list, so a mistaken block would
/// permanently and invisibly remove someone from your pool with no way
/// back. A control you cannot reverse is not a preference, it is a trap.
class BlockedPlayersScreen extends StatefulWidget {
  const BlockedPlayersScreen({super.key});

  @override
  State<BlockedPlayersScreen> createState() => _BlockedPlayersScreenState();
}

class _BlockedPlayersScreenState extends State<BlockedPlayersScreen> {
  bool _loading = true;
  bool _busy = false;
  String? _error;
  List<Map<String, dynamic>> _players = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final result = await FirebaseFunctions.instance
          .httpsCallable('getBlockedPlayers')
          .call<Map<String, dynamic>>();
      if (!mounted) return;
      setState(() {
        _players = ((result.data['players'] as List?) ?? const [])
            .map((e) => (e as Map).cast<String, dynamic>())
            .toList();
        _loading = false;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = "Couldn't load your block list.";
        });
      }
    }
  }

  Future<void> _unblock(String uid, String name) async {
    setState(() => _busy = true);
    try {
      await FirebaseFunctions.instance
          .httpsCallable('setBlocked')
          .call<Map<String, dynamic>>({'userId': uid, 'blocked': false});
      if (!mounted) return;
      setState(() {
        _players = _players.where((p) => p['uid'] != uid).toList();
        _busy = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Unblocked $name.')),
      );
    } catch (_) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = "Couldn't unblock. Try again.";
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Blocked Players')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(_error!),
                  ),
                Expanded(
                  child: _players.isEmpty
                      ? const Center(
                          child: Padding(
                            padding: EdgeInsets.all(32),
                            child: Text(
                              "You haven't blocked anyone.\n\n"
                              "Blocking is private - the other person is "
                              'never told, and it only means the two of you '
                              'are never paired again.',
                              textAlign: TextAlign.center,
                            ),
                          ),
                        )
                      : ListView.builder(
                          itemCount: _players.length,
                          itemBuilder: (context, i) {
                            final p = _players[i];
                            final name = p['username'] as String? ?? 'Unknown';
                            return ListTile(
                              leading: const Icon(Icons.block),
                              title: Text(name),
                              trailing: TextButton(
                                onPressed: _busy
                                    ? null
                                    : () => _unblock(p['uid'] as String, name),
                                child: const Text('Unblock'),
                              ),
                            );
                          },
                        ),
                ),
              ],
            ),
    );
  }
}

/// Confirms and applies a block. Shared by every surface that offers it.
///
/// Confirmed rather than instant, because the consequence is invisible:
/// nothing afterwards tells you the pool got smaller, so an accidental
/// tap would go unnoticed. Says plainly that it is private and reversible,
/// since the fear that stops people blocking is usually that the other
/// person will find out.
Future<bool> confirmBlock(
    BuildContext context, String userId, String username) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text('Block $username?'),
      content: const Text(
        "You won't be paired with them again, and you won't find each "
        "other in search.\n\nThey are never told, and you can undo this "
        'any time from your profile.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: const Text('Block'),
        ),
      ],
    ),
  );
  if (confirmed != true) return false;

  try {
    await FirebaseFunctions.instance
        .httpsCallable('setBlocked')
        .call<Map<String, dynamic>>({'userId': userId, 'blocked': true});
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Blocked $username.')),
      );
    }
    return true;
  } on FirebaseFunctionsException catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.message ?? "Couldn't block them.")),
      );
    }
    return false;
  }
}
