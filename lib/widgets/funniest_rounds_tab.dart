import 'package:flutter/material.dart';

import '../core/services/funniest_rounds_service.dart';
import 'empty_state.dart';
import 'match_clip_player.dart';

/// The Funniest Rounds board (a tab on the Ranks screen).
///
/// Battles ranked by how many judges marked one of their rounds the funniest
/// - a content hall-of-fame for MOMENTS, deliberately NOT a second skill rank
/// (it never touches rating or titles). Another thing to shoot for.
class FunniestRoundsTab extends StatefulWidget {
  const FunniestRoundsTab({super.key});

  @override
  State<FunniestRoundsTab> createState() => _FunniestRoundsTabState();
}

class _FunniestRoundsTabState extends State<FunniestRoundsTab> {
  final _service = FunniestRoundsService();
  List<FunniestRound>? _rounds;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await _service.fetch();
      if (mounted) setState(() => _rounds = r);
    } catch (_) {
      if (mounted) setState(() => _error = 'Could not load the board.');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Center(
        child: Text(_error!, style: const TextStyle(color: Colors.white70)),
      );
    }
    final rounds = _rounds;
    if (rounds == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (rounds.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(horizontal: 24),
        child: EmptyState(
          icon: Icons.local_fire_department_outlined,
          title: 'No best rounds yet',
          message: 'Judge some battles and tap the flame on the round that '
              'got you. The best rounds land here.',
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.builder(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
        itemCount: rounds.length,
        itemBuilder: (context, i) => _card(context, rounds[i], i + 1),
      ),
    );
  }

  Widget _card(BuildContext context, FunniestRound r, int position) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: const Color(0xFF141019),
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: r.videoUrl == null ? null : () => _watch(context, r),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              children: [
                SizedBox(
                  width: 24,
                  child: Text('$position',
                      style: const TextStyle(
                          color: Colors.white54,
                          fontSize: 18,
                          fontWeight: FontWeight.bold)),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('${r.player1Username} vs ${r.player2Username}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold)),
                      const SizedBox(height: 4),
                      Text(
                        r.round == null
                            ? 'Best round'
                            : 'Round ${r.round! + 1} - best round',
                        style: const TextStyle(
                            color: Colors.white70, fontSize: 13),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.local_fire_department,
                        color: Color(0xFFEA4C6D), size: 20),
                    Text('${r.votes}',
                        style: const TextStyle(
                            color: Colors.white, fontSize: 12)),
                  ],
                ),
                if (r.videoUrl != null) ...[
                  const SizedBox(width: 8),
                  const Icon(Icons.play_circle_outline, color: Colors.white70),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _watch(BuildContext context, FunniestRound r) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => Scaffold(
          backgroundColor: Colors.black,
          appBar: AppBar(
            backgroundColor: Colors.black,
            title: Text(
              r.round == null
                  ? '${r.player1Username} vs ${r.player2Username}'
                  : 'Round ${r.round! + 1} · ${r.player1Username} vs ${r.player2Username}',
              style: const TextStyle(fontSize: 14),
            ),
          ),
          // When the battle recorded per-round boundaries, play ONLY the
          // voted-best round; otherwise fall back to the whole clip.
          body: Center(
            child: MatchClipPlayer(
              videoUrl: r.videoUrl,
              startMs: r.startMs,
              endMs: r.endMs,
            ),
          ),
        ),
      ),
    );
  }
}
