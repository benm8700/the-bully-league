import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../core/services/event_window.dart';
import '../core/services/presence.dart';

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
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(live ? Icons.local_fire_department : Icons.schedule),
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
                        ],
                      ),
                    ),
                  ],
                ),
                // Pre-commitment, shown only ahead of the window. Once it
                // is running, "I'm in tonight" is a worse call to action
                // than simply battling, which is already one tap away.
                if (!live)
                  _CommitRow(dayKey: upcomingWindowDayKey(now, config)),
              ],
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

        return Padding(
          padding: const EdgeInsets.only(top: 10),
          child: Row(
            children: [
              committed
                  ? OutlinedButton.icon(
                      onPressed: () => userRef.set({
                        'eventCommitmentDayKey': null,
                      }, SetOptions(merge: true)),
                      icon: const Icon(Icons.check_circle, size: 18),
                      label: const Text("You're in tonight"),
                    )
                  : FilledButton.tonal(
                      onPressed: () => userRef.set({
                        'eventCommitmentDayKey': dayKey,
                      }, SetOptions(merge: true)),
                      child: const Text("I'm in tonight"),
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
