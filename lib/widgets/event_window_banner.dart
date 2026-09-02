import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../core/services/event_window.dart';
import '../core/services/presence.dart';
import '../screens/tournament/tournament_list_screen.dart';
import '../theme/app_theme.dart';

/// The always-visible countdown to the daily window.
///
/// This is the cheapest and most durable way to teach the habit: a
/// notification is a single moment that can be missed or muted, whereas a
/// countdown sitting on Home sets the rhythm every time the app is opened,
/// including for people who never granted notification permission.
///
/// Reads its config live from `config/eventWindow`, so the name and hours -
/// both explicitly provisional - can be retuned without shipping a new
/// version. Renders nothing at all when disabled or unreadable: a broken
/// or switched-off promo must never be the reason Home looks wrong.
class EventWindowBanner extends StatefulWidget {
  const EventWindowBanner({super.key});

  @override
  State<EventWindowBanner> createState() => _EventWindowBannerState();
}

class _EventWindowBannerState extends State<EventWindowBanner> {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    // Once a minute is enough for a countdown displayed in minutes, and is
    // far cheaper than a per-second rebuild for something that sits on
    // screen the whole time someone is browsing.
    _ticker = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection('config')
          .doc('eventWindow')
          .snapshots(),
      builder: (context, snapshot) {
        if (snapshot.hasError) return const SizedBox.shrink();
        // Falls back to the documented defaults when the document doesn't
        // exist yet, so the banner works before anyone creates it.
        final config = EventWindowConfig.fromMap(snapshot.data?.data());
        if (!config.enabled) return const SizedBox.shrink();

        final now = DateTime.now().toUtc();
        final window = currentOrNextWindow(now, config);
        final live = window.contains(now);

        return Card(
          color: live
              ? Theme.of(context).colorScheme.primaryContainer
              : Theme.of(context).colorScheme.surfaceContainerHighest,
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            // The whole banner is the way in to tonight's tournament - tap to
            // the tournament list, where check-in lives. The "I'm in tonight"
            // button inside keeps its own tap.
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => const TournamentListScreen(),
              ),
            ),
            child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(live ? Icons.local_fire_department : Icons.schedule,
                        color: live ? context.palette.live : null),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            live ? '${config.name} is LIVE' : config.name,
                            style: Theme.of(context).textTheme.titleSmall
                                ?.copyWith(fontWeight: FontWeight.bold),
                          ),
                          const SizedBox(height: 2),
                          // Frames the window as what it now IS - the nightly
                          // tournament, the one place prestige and prizes are
                          // on the line - so it reads as the headline event
                          // rather than just a points-multiplier hour.
                          Text(
                            live
                                ? 'The nightly tournament is on - join the bracket'
                                : 'The nightly tournament - win prestige & prizes',
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(
                                    color: context.palette.reward,
                                    fontWeight: FontWeight.w600),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            live
                                ? '${_remaining(window.end, now)} left - most people are online now'
                                : 'Starts in ${_remaining(window.start, now)}',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                          const SizedBox(height: 2),
                          // The canonical time stays "6-7 Pacific" so the name
                          // means the same thing to everyone, but nobody should
                          // have to do timezone arithmetic to use it.
                          Text(
                            _localTimeLabel(window, config),
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                          // The single most persuasive thing on this banner:
                          // the objection is "nobody will be there," and a real
                          // number answers it directly. Rendered only when
                          // there IS somebody - "0 roasters online" is an
                          // argument against opening the app.
                          const _OnlineCountLine(),
                      // The reward, said out loud. The backend has been
                      // doubling points inside the window since it was
                      // built, and nothing told anyone - a bonus nobody
                      // knows about motivates nobody. Read from the same
                      // live config the server uses, so retuning it to 3x
                      // changes this copy too rather than leaving the app
                      // promising the wrong number.
                      _MultiplierLine(live: live),
                        ],
                      ),
                    ),
                  ],
                ),
                // The explicit CTA during the window. The whole card is
                // tappable, but a card with no visible button is a weak
                // affordance - many people never realise they can tap it. This
                // is the headline's clear action, right at the decision point
                // where the urgency (time left, 2x points) is being read. It
                // reinforces the app-wide LIVE bar rather than duplicating it:
                // the bar is the persistent glance-nudge, this is the in-context
                // "do it now" button.
                if (live) ...[
                  const SizedBox(height: 8),
                  // Two entry points side by side. The GOLD "Join Tournament"
                  // (metallic gold gradient + glow, so it reads like a
                  // win-money/prize button, distinct from the pink "Roast
                  // Someone Now" below) is the headline action for battlers.
                  // The secondary "Watch" invites SPECTATORS in - people who do
                  // not want to battle but will watch the live bracket and
                  // vote/judge, which is the scarce resource the ladder runs
                  // on. Both go to the tournament, where check-in AND the live
                  // watch/vote list live.
                  Row(
                    children: [
                      _goldTournamentButton(context, 'Join Tournament'),
                      const SizedBox(width: 10),
                      // Spectator entry, now COLOURED (filled purple secondary)
                      // to actively pull people into watching + judging - votes
                      // are the scarce resource the ladder runs on, so this is
                      // worth encouraging, not just offering. Distinct from the
                      // gold Join and the pink primary. An eye icon so it reads
                      // as "watch" at a glance.
                      FilledButton.icon(
                        onPressed: () => Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => const TournamentListScreen(),
                          ),
                        ),
                        style: FilledButton.styleFrom(
                          backgroundColor:
                              Theme.of(context).colorScheme.secondary,
                          foregroundColor:
                              Theme.of(context).colorScheme.onSecondary,
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.symmetric(
                              horizontal: 14, vertical: 9),
                        ),
                        icon: const Icon(Icons.remove_red_eye_outlined,
                            size: 16),
                        label: const Text('Watch'),
                      ),
                    ],
                  ),
                ],
                // Before the window: the SAME gold tournament button (the
                // developer's favourite, so it lives here too) leading to
                // tonight's tournament, plus the "I'm in tonight" pre-commit.
                // Once the window is running, "I'm in tonight" is a worse call
                // to action than simply battling, so it only shows ahead.
                if (!live) ...[
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: _goldTournamentButton(
                        context, "Tonight's Tournament"),
                  ),
                  const SizedBox(height: 8),
                  _CommitRow(dayKey: upcomingWindowDayKey(now, config)),
                ],
              ],
            ),
          ),
          ),
        );
      },
    );
  }

  String _remaining(DateTime target, DateTime now) {
    final d = target.difference(now);
    if (d.isNegative) return '0m';
    final hours = d.inHours;
    final minutes = d.inMinutes % 60;
    if (hours >= 1) return '${hours}h ${minutes}m';
    return '${d.inMinutes}m';
  }

  String _localTimeLabel(
    EventWindowOccurrence window,
    EventWindowConfig config,
  ) {
    final startLocal = window.start.toLocal();
    final endLocal = window.end.toLocal();
    final pacific =
        '${_hour12(config.startHourPacific)}-${_hour12(config.endHourPacific)} Pacific';
    final local = '${_clock(startLocal)}-${_clock(endLocal)}';
    // Someone actually in Pacific shouldn't be told the same thing twice.
    if (_clock(startLocal) == _hour12(config.startHourPacific) &&
        _clock(endLocal) == _hour12(config.endHourPacific)) {
      return pacific;
    }
    return '$pacific - $local your time';
  }

  String _hour12(int hour24) {
    final h = hour24 % 12 == 0 ? 12 : hour24 % 12;
    return '$h${hour24 < 12 ? 'am' : 'pm'}';
  }

  String _clock(DateTime local) {
    final h = local.hour % 12 == 0 ? 12 : local.hour % 12;
    final suffix = local.hour < 12 ? 'am' : 'pm';
    if (local.minute == 0) return '$h$suffix';
    return '$h:${local.minute.toString().padLeft(2, '0')}$suffix';
  }
}

/// The metallic-gold "win money / prize" tournament button, reused on both the
/// live and pre-window banner states. Pale-gold -> vivid gold -> deep gold
/// with a gold glow; a plain FilledButton can't gradient, so this is a custom
/// Ink button. Deliberately a DIFFERENT colour from the pink "Roast a
/// Stranger" primary so the two never read as the same action. Goes to the
/// tournament, where check-in and the live watch/vote list live.
Widget _goldTournamentButton(BuildContext context, String label) {
  return Material(
    color: Colors.transparent,
    borderRadius: BorderRadius.circular(24),
    child: InkWell(
      borderRadius: BorderRadius.circular(24),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const TournamentListScreen()),
      ),
      child: Ink(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(24),
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFFFCE9A6), Color(0xFFF4C838), Color(0xFFCF9A15)],
            stops: [0.0, 0.5, 1.0],
          ),
          // A thin earthy-brown outline that follows the rounded pill, INSTEAD
          // of the old gold glow - the glow's soft square halo bled past the
          // rounded corners and looked messy. Fully rounded, no excess corners.
          border: Border.all(color: const Color(0xFF7A5A12), width: 1.5),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.emoji_events, size: 16, color: Color(0xFF4A3500)),
              const SizedBox(width: 8),
              Text(
                label,
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                      color: const Color(0xFF3D2C00),
                      fontWeight: FontWeight.w800,
                    ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

/// "N roasters online now", or nothing at all.
///
/// Deliberately renders nothing when the count is zero, stale, or
/// unreadable. This line only ever exists to make the app look alive; a
/// "0 roasters online" label would be an argument against opening it, and a
/// frozen number from an hour ago would be a lie that costs the counter its
/// credibility the first time someone queues against it.
class _OnlineCountLine extends StatelessWidget {
  const _OnlineCountLine();

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<OnlineCount?>(
      stream: onlineCountStream(),
      builder: (context, snapshot) {
        final count = snapshot.data;
        if (count == null || !count.isFresh || count.total <= 0) {
          return const SizedBox.shrink();
        }
        return Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Row(
            children: [
              const Icon(Icons.circle, size: 8, color: Colors.greenAccent),
              const SizedBox(width: 6),
              Text(
                count.label,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(fontWeight: FontWeight.bold),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// "I'm in tonight" — pre-commitment, plus how many others have said so.
///
/// Two distinct payoffs, and the second is the one people underrate:
///  1. Stating an intention measurably raises follow-through. It is the
///     cheapest retention mechanic available and costs the user one tap.
///  2. It produces a PREDICTABLE POOL SIZE. Matchmaking currently hopes
///     enough people turn up at once; this turns that hope into a number
///     visible before the window opens, which both reassures the person
///     deciding whether to bother and tells the developer whether tonight
///     is worth being online to seed.
///
/// The count is deliberately shown only when someone has actually
/// committed. "0 people are in tonight" is an argument against showing up,
/// which is the precise opposite of the intended effect - the same honesty
/// rule the live online count follows.
class _CommitRow extends StatelessWidget {
  const _CommitRow({required this.dayKey});

  /// The Pacific day of the window being committed to. Keyed this way
  /// rather than by the viewer's local date so that everyone worldwide
  /// commits to the same night.
  final String dayKey;

  @override
  Widget build(BuildContext context) {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return const SizedBox.shrink();
    final userRef = FirebaseFirestore.instance.collection('users').doc(uid);

    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: userRef.snapshots(),
      builder: (context, snapshot) {
        if (snapshot.hasError) return const SizedBox.shrink();
        final committed =
            snapshot.data?.data()?['eventCommitmentDayKey'] == dayKey;

        // Tinted with the REWARD token (the "prize hour" gold), not the
        // primary accent. This deliberately gives the pre-commit box a
        // little pull of its own - Sixes and Sevens is what we most want to
        // captivate people with - while still keeping the solid primary CTA
        // as the one true accent on the screen. A tonal fill + icon reads
        // as inviting without shouting louder than "Find Opponent".
        final reward = context.palette.reward;
        // A compact button style so the banner stays tight - the default
        // 48px tap target plus padding makes it taller than it needs to be.
        final commitStyle = FilledButton.styleFrom(
          foregroundColor: reward,
          visualDensity: VisualDensity.compact,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        );
        return Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Row(
            children: [
              committed
                  ? FilledButton.tonalIcon(
                      onPressed: () => userRef.set({
                        'eventCommitmentDayKey': null,
                      }, SetOptions(merge: true)),
                      style: commitStyle.copyWith(
                        backgroundColor: WidgetStatePropertyAll(
                            reward.withValues(alpha: 0.18)),
                      ),
                      icon: const Icon(Icons.check_circle, size: 18),
                      label: const Text("You're in tonight"),
                    )
                  : FilledButton.tonalIcon(
                      onPressed: () => userRef.set({
                        'eventCommitmentDayKey': dayKey,
                      }, SetOptions(merge: true)),
                      style: commitStyle.copyWith(
                        backgroundColor: WidgetStatePropertyAll(
                            reward.withValues(alpha: 0.14)),
                      ),
                      icon: const Icon(Icons.star_rounded, size: 18),
                      label: const Text("I'm in tonight"),
                    ),
              const SizedBox(width: 12),
              const Expanded(child: _CommittedCountLine()),
            ],
          ),
        );
      },
    );
  }
}

/// "12 in tonight", or nothing.
class _CommittedCountLine extends StatelessWidget {
  const _CommittedCountLine();

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<OnlineCount?>(
      stream: onlineCountStream(),
      builder: (context, snapshot) {
        final count = snapshot.data;
        if (count == null || !count.isFresh || count.committedTonight <= 0) {
          return const SizedBox.shrink();
        }
        return Text(
          '${count.committedTonight} in tonight',
          style: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(fontWeight: FontWeight.bold),
        );
      },
    );
  }
}

/// "2x points on every battle and every vote."
///
/// Reads the multiplier from `config/pointsSettings` - the same document
/// the server awards from - so the promise on screen and the number
/// actually paid cannot drift apart. Renders nothing if the multiplier is
/// 1 or the config is unreadable, since announcing a bonus that isn't
/// being paid is worse than saying nothing.
class _MultiplierLine extends StatelessWidget {
  const _MultiplierLine({required this.live});

  final bool live;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection('config')
          .doc('pointsSettings')
          .snapshots(),
      builder: (context, snapshot) {
        if (snapshot.hasError) return const SizedBox.shrink();
        // Defaults to the documented 2x so the line still appears before
        // anyone creates the config document.
        final raw = snapshot.data?.data()?['eventWindowMultiplier'];
        final multiplier = raw is num ? raw.toDouble() : 2.0;
        if (multiplier <= 1) return const SizedBox.shrink();
        final label = multiplier == multiplier.roundToDouble()
            ? multiplier.toStringAsFixed(0)
            : multiplier.toString();

        return Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Row(
            children: [
              Icon(Icons.bolt, size: 14, color: context.palette.reward),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  live
                      ? '${label}x points right now - battling and judging'
                      : '${label}x points during the hour',
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
