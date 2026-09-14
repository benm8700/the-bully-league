import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../core/services/event_window.dart';
import '../core/services/presence.dart';
import '../screens/tournament/tournament_list_screen.dart';
import '../theme/app_theme.dart';
import 'battle_mode_card.dart';

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

        final scheme = Theme.of(context).colorScheme;
        final text = Theme.of(context).textTheme;

        void openTournament() => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => const TournamentListScreen(),
              ),
            );

        // LIVE: the event is happening now. Red accent; the two actions (join
        // the bracket / watch) sit in the footer so the card still reads as a
        // single option with its own tap.
        if (live) {
          return BattleModeCard(
            accent: context.palette.live,
            icon: Icons.local_fire_department,
            title: '${config.name} is LIVE',
            subtitle: 'The nightly tournament is on - join the bracket',
            status: Text(
              '${_remaining(window.end, now)} left · most people are online now',
              style: text.bodySmall,
            ),
            onTap: openTournament,
            footer: Row(
              children: [
                _goldTournamentButton(context, 'Join Tournament'),
                const SizedBox(width: 10),
                FilledButton.icon(
                  onPressed: openTournament,
                  style: FilledButton.styleFrom(
                    backgroundColor: scheme.secondary,
                    foregroundColor: scheme.onSecondary,
                    visualDensity: VisualDensity.compact,
                    padding:
                        const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                  ),
                  icon: const Icon(Icons.remove_red_eye_outlined, size: 16),
                  label: const Text('Watch'),
                ),
              ],
            ),
          );
        }

        // PRE-WINDOW: the prize event, later tonight. Same BattleModeCard shell
        // as Home's "Roast a Stranger" (developer's redesign, 2026-09-14), so
        // the two read as two options of one kind - the prize event TONIGHT vs
        // a casual battle NOW. Gold accent; the "?" explainer sits top-right
        // and the "I'm in tonight" pre-commit in the footer, both genuinely
        // different actions from the card's own tap.
        return BattleModeCard(
          accent: context.palette.reward,
          icon: Icons.emoji_events,
          title: config.name,
          subtitle: 'The nightly bracket - win prestige & prizes',
          status: Text.rich(
            TextSpan(
              style: text.bodySmall,
              children: [
                TextSpan(
                    text:
                        '${_hour12(config.startHourPacific)}-${_hour12(config.endHourPacific)} Pacific · starts in '),
                TextSpan(
                  text: _remaining(window.start, now),
                  style: TextStyle(
                    color: context.palette.reward,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
          trailing: IconButton(
            icon: const Icon(Icons.help_outline),
            iconSize: 20,
            visualDensity: VisualDensity.compact,
            color: scheme.onSurfaceVariant,
            tooltip: 'About this tournament',
            onPressed: () => _showTournamentInfo(context, config),
          ),
          onTap: openTournament,
          // The "I'm in tonight" pre-commit lives INSIDE the card (footer);
          // Home's "Roast a Stranger" card carries a matching online-count
          // footer so the two stay the same size (developer's call,
          // 2026-09-14).
          footer: _CommitRow(dayKey: upcomingWindowDayKey(now, config)),
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

  /// The full date + time of tonight's window, Pacific-anchored:
  /// "Friday, September 12, 6pm-7pm Pacific". Deliberately "Pacific", not
  /// "PST" - PST is winter-only (CLAUDE.md's copy note). Month/weekday names
  /// are hardcoded rather than via `intl` to keep the fragile Android
  /// toolchain free of another dependency, same reason the Pacific clock is
  /// pure Dart.
  String _windowDateLabel(
    EventWindowOccurrence window,
    EventWindowConfig config,
  ) {
    // Shift the UTC window start by the Pacific offset to read its Pacific
    // wall-clock date components (same trick as upcomingWindowDayKey).
    final p = window.start.add(pacificOffset(window.start));
    const weekdays = [
      'Monday', 'Tuesday', 'Wednesday', 'Thursday',
      'Friday', 'Saturday', 'Sunday',
    ];
    const months = [
      'January', 'February', 'March', 'April', 'May', 'June',
      'July', 'August', 'September', 'October', 'November', 'December',
    ];
    final time =
        '${_hour12(config.startHourPacific)}-${_hour12(config.endHourPacific)} Pacific';
    return '${weekdays[p.weekday - 1]}, ${months[p.month - 1]} ${p.day}, $time';
  }

  /// Explains the nightly tournament: what it is, the rules, the prize, and
  /// the 2x bonus. Opened by the "?" beside the tournament button.
  void _showTournamentInfo(BuildContext context, EventWindowConfig config) {
    final hours =
        '${_hour12(config.startHourPacific)}-${_hour12(config.endHourPacific)} Pacific';
    final body = Theme.of(context).textTheme.bodyMedium;
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(config.name),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'The nightly tournament - $hours, every night. One hour, one '
                'crowd, one champion.',
                style: body,
              ),
              const SizedBox(height: 16),
              _infoHeading(context, 'How it works'),
              Text(
                'Hop in any time during the hour - everyone starts at 0 wins. '
                "You're paired with someone who has the same number of wins as "
                "you. Win, and you move up. Lose, and you're out - but you can "
                'stick around to watch and vote. Keep winning to climb, and the '
                'last one standing takes the crown. If the clock runs out '
                "first, whoever's climbed highest wins it.",
                style: body,
              ),
              const SizedBox(height: 16),
              _infoHeading(context, 'The prize'),
              Text(
                'Prestige, and prizes when they are on the line. It is free to '
                'enter and the champion takes the night. Bigger cash-prize '
                'events run on top from time to time.',
                style: body,
              ),
              const SizedBox(height: 16),
              _infoHeading(context, 'The bonus'),
              Text(
                'Everything counts double during the hour - 2x points on every '
                'battle AND every vote.',
                style: body,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Got it'),
          ),
        ],
      ),
    );
  }

  Widget _infoHeading(BuildContext context, String label) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Text(
        label,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.bold,
              color: context.palette.reward,
            ),
      ),
    );
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
/// Width of the gold "Tonight: 6s and 7s Tournament" pill's footprint, reused
/// on Home so the "Roast a Stranger" pill matches it exactly (developer's call,
/// 2026-09-14). The two labels differ, so neither would otherwise be the same
/// width; pinning both to one value keeps them a matched pair. Tuned to the
/// gold pill's rendered width on a ~411dp phone — revisit if the tournament
/// label or the display font changes.
const double kEventPillWidth = 272;

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
        // Height matched to the gold "Tonight" and pink "Roast a Stranger"
        // pills (developer's call, 2026-09-14): the theme's FilledButton
        // minimumSize (Size.fromHeight(52)) was making this box taller than
        // those two, so it is dropped here (Size(0,0)) and the vertical padding
        // set to 9 to mirror them. WIDTH is left to hug the label (content
        // width) on purpose - only the height was matched.
        // No visualDensity.compact here: the gold "Tonight" and pink "Roast a
        // Stranger" pills use the default density, so compact would leave this
        // one a few px shorter than them. minimumSize(0,0) + vertical padding 9
        // matches their height exactly; width still hugs the label.
        final commitStyle = FilledButton.styleFrom(
          foregroundColor: reward,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          minimumSize: const Size(0, 0),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
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
        final n = count.committedTonight;
        return Text(
          n == 1 ? '1 person has signed up' : '$n people have signed up',
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
