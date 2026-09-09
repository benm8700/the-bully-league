import 'dart:async';
import 'dart:math' as math;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';

import '../../widgets/laugh_meter.dart';
import 'package:provider/provider.dart';

import '../../core/services/auth_service.dart';
import '../../core/services/entitlement_service.dart';
import '../../core/services/matchmaking_service.dart';
import '../../core/services/push_notification_service.dart';
import '../../widgets/admin_only.dart';
import '../../widgets/daily_quests.dart';
import '../../widgets/event_window_banner.dart';
import '../match/bio_reveal_screen.dart';
import '../match/pre_match_screen.dart';
import '../match/recording_consent_screen.dart';
import '../onboarding/tutorial_screen.dart';
import '../friends/challenge_screen.dart';
import '../practice/solo_practice_screen.dart';
import '../settings/notification_settings_screen.dart';
import '../info/rules_screen.dart';
import '../vote/finalize_test_screen.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final authService = context.read<AuthService>();

    return Scaffold(
      appBar: AppBar(
        title: const Text('The Bully League'),
        actions: [
          // Help (how a battle works / support) lives next to the Rules
          // button at the bottom now, not up here.
          IconButton(
            icon: const Icon(Icons.notifications_outlined),
            tooltip: 'Notifications',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => const NotificationSettingsScreen(),
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.logout),
            tooltip: 'Sign out',
            onPressed: () => _signOut(context, authService),
          ),
        ],
      ),
      // Listens rather than reading currentUser once: right after sign-up,
      // the account is created (and this screen shown) before the
      // displayName update lands, so this needs to pick up that follow-up
      // update once it arrives instead of freezing on the first snapshot.
      body: StreamBuilder<User?>(
        stream: authService.authStateChanges(),
        initialData: authService.currentUser,
        builder: (context, snapshot) {
          final username = snapshot.data?.displayName ?? 'Roaster';
          final uid = snapshot.data?.uid;
          // Scrollable rather than a bare centred Column: Home has grown
          // past what a small screen can show at once (seen live as a
          // 156px overflow on a 320x640 device), and it will keep growing.
          // Centred only when there's room to spare, so it still looks
          // deliberate on a large phone rather than pinned to the top.
          return LayoutBuilder(
            builder: (context, constraints) => SingleChildScrollView(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  minHeight: constraints.maxHeight - 32,
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    // Quiet on purpose. A greeting is furniture - the
                    // player already knows who they are - and the first
                    // pass had it as the loudest thing on the screen,
                    // above their own rank. The rank is the identity
                    // here, so the Laugh Meter below carries the size.
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      child: Text(
                        username.toUpperCase(),
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.labelSmall,
                      ),
                    ),
                    const SizedBox(height: 8),
                    if (uid != null) _RankBadge(uid: uid),
                    const SizedBox(height: 18),
                    // Anything urgent stays at the very top: a match
                    // waiting, or somebody challenging you.
                    const _ActiveMatchBanner(),
                    const _IncomingChallengeBanner(),
                    const _TrialStatus(),
                    const SizedBox(height: 8),
                    // THE HEADLINE: Sixes and Sevens IS the nightly
                    // tournament (CLAUDE.md), so it leads - prestige and
                    // prizes live here, and it is where everyone is pointed
                    // first. Tapping it goes to the tournament, where
                    // check-in lives.
                    const EventWindowBanner(),
                    const SizedBox(height: 16),
                    // The primary action sits DIRECTLY UNDER the headline so
                    // it is always above the fold - even on a short real phone
                    // (the layout was tuned on a taller emulator), and even
                    // with the live-cue bar pushing content down during the
                    // window. This is why the quests + points/XP bar moved
                    // BELOW it: the CTA being visible without scrolling beats
                    // the XP bar being above the fold.
                    FilledButton(
                      onPressed: () => _startMatch(context, 'ranked'),
                      // "Roast a Stranger": names exactly what the app is (you
                      // roast a random stranger), which the developer judged
                      // reads better for the app's identity than "Roast Someone
                      // Now" / "Find Opponent". "Find" read like browsing a
                      // list rather than doing something.
                      child: const Text('Roast a Stranger'),
                    ),
                    const SizedBox(height: 22),
                    // Daily progress - the quests and the points/clip (XP)
                    // bar - sits just under the primary action.
                    const DailyQuests(),
                    const SizedBox(height: 4),
                    if (uid != null) _PointsBalanceForUser(uid: uid),
                    const SizedBox(height: 24),
                    // Everything below is navigation rather than the
                    // day's business, and the rule says so without a
                    // heading nobody would read.
                    const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 32),
                      child: Divider(),
                    ),
                    const SizedBox(height: 20),
                    // Practice-vs-a-stranger (the `exhibition` matchmaking
                    // mode) is gone from Home, collapsed into SOLO practice
                    // (2026-08-31): less is better, and the two real draws are
                    // the nightly tournament and Roast Someone Now. Warming up
                    // is a solo activity anyway, and solo practice still lives
                    // where it is actually wanted - the matchmaking screen
                    // offers "Warm up solo instead" for the empty-queue case.
                    // Battle a friend leads the navigation trio now.
                    //
                    // Sits with the battle actions because it IS a way to
                    // start a battle - and with a thin pool it is the most
                    // reliable one there is.
                    OutlinedButton.icon(
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => const ChallengeScreen(),
                        ),
                      ),
                      icon: const Icon(Icons.person_add_alt_1_outlined,
                          size: 18),
                      label: const Text('Battle a friend'),
                    ),
                    // Solo practice is no longer offered here - Home is for
                    // battling and the day's business, not warm-ups. It
                    // still lives where it is actually wanted: the
                    // matchmaking screen offers "Warm up solo instead" for
                    // the empty-queue case, which is its real job.
                    //
                    // Judging, My Battles, Ranks and Profile are bottom-nav
                    // destinations now (see MainShell), so they are
                    // deliberately not repeated here - a second route to
                    // the same screen just makes this list longer and the
                    // tabs look decorative.
                    AdminOnly(
                      child: Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: OutlinedButton(
                          onPressed: () => Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => const FinalizeTestScreen(),
                            ),
                          ),
                          child: const Text('Finalize Match (test)'),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    // The "Tournaments" button was removed: Sixes and Sevens
                    // IS the tournament, and its headline banner above already
                    // taps through to the tournament list, so a separate
                    // button was a second route to the same place. In its
                    // spot, the rules - the one thing a new player wants and
                    // had nowhere to find.
                    // A single "How it works" entry, replacing the old Rules
                    // button + help menu. It opens the rules, and the
                    // interactive demo ("how a battle works") plus a support
                    // link live at the bottom of that one screen.
                    OutlinedButton.icon(
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => const RulesScreen(),
                        ),
                      ),
                      icon: const Icon(Icons.menu_book_outlined, size: 18),
                      label: const Text('How it works'),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  /// Drops this device's push token before signing out, so the next person
  /// to sign in here doesn't receive the previous account's match alerts.
  /// Best-effort: a failure to clean up the token must not trap someone in
  /// an account they're trying to leave, so sign-out proceeds regardless.
  Future<void> _signOut(BuildContext context, AuthService authService) async {
    final push = context.read<PushNotificationService>();
    try {
      await push.unregister();
    } catch (_) {
      // Intentionally ignored - see above.
    }
    await authService.signOut();
  }
}

/// Recording consent -> camera/mic check -> matchmaking queue -> match.
///
/// Mode is chosen here and carried all the way through, because each mode
/// has its own matchmaking queue - an exhibition player is never paired
/// into a match that moves someone's rating.
///
/// Top-level rather than a method so both the exhibition button and the
/// Ranked unlock gate can start the flow without one reaching into the
/// other's widget.
Future<void> _startMatch(BuildContext context, String mode) async {
  // Asked FIRST, before anything that costs the player effort. Without
  // this a lapsed player sits through the tutorial gate, the recording
  // consent screen and the entire camera-and-mic check, and only then gets
  // turned away by the queue - the worst possible moment to say no, and it
  // reads as a bug rather than a price. The server still enforces; this
  // just turns a late refusal into an early offer.
  final entitlement = await EntitlementService().current();
  if (!context.mounted) return;
  if (!entitlement.allows(mode)) {
    await _showBlockedSheet(context, entitlement, mode);
    return;
  }

  // The tutorial is a mandatory one-time gate before a first match
  // (CLAUDE.md's Onboarding tutorial decision). Checked here rather than
  // on Home so it fires at the moment it's relevant - someone browsing
  // the leaderboard shouldn't be made to sit through it.
  if (!await _ensureTutorialCompleted(context)) return;
  if (!context.mounted) return;

  final consented = await Navigator.of(context).push<bool>(
    MaterialPageRoute(builder: (_) => const RecordingConsentScreen()),
  );
  if (consented != true || !context.mounted) return;

  await Navigator.of(
    context,
  ).push(MaterialPageRoute(builder: (_) => PreMatchScreen(mode: mode)));
}

/// Says where this player stands: how much trial is left, or what a
/// lapsed account still gets for free.
///
/// A trial only converts if people KNOW it is ending, so this is not
/// decoration - it is the mechanism. Equally, someone whose trial has
/// ended must be told what they still have (ranked, free, every night)
/// rather than just losing access and guessing why.
///
/// Renders NOTHING while enforcement is off, which is the current state:
/// counting down a trial that expires into no restriction at all would be
/// a threat the app has no intention of carrying out.
class _TrialStatus extends StatefulWidget {
  const _TrialStatus();

  @override
  State<_TrialStatus> createState() => _TrialStatusState();
}

class _TrialStatusState extends State<_TrialStatus> {
  Entitlement? _entitlement;

  @override
  void initState() {
    super.initState();
    EntitlementService().current().then((e) {
      if (mounted) setState(() => _entitlement = e);
    });
  }

  @override
  Widget build(BuildContext context) {
    final e = _entitlement;
    if (e == null || !e.enforced || e.state == 'subscriber') {
      return const SizedBox.shrink();
    }

    final windowName = e.windowName ?? 'the daily window';
    final daysLeft = e.trialDaysLeft;
    final String message;
    if (e.state == 'trial') {
      if (daysLeft == null) return const SizedBox.shrink();
      message = daysLeft <= 1
          ? 'Last day of full access. After that, the nightly $windowName '
              'tournament stays free.'
          : '$daysLeft days of full access left.';
    } else {
      message = e.inWindow
          ? '$windowName is live - jump in free right now.'
          : 'Join the nightly $windowName tournament free, every night.';
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
      child: Text(
        message,
        textAlign: TextAlign.center,
        style: Theme.of(context).textTheme.bodySmall,
      ),
    );
  }
}

/// The spendable points balance, framed by what it actually buys.
///
/// A bare count says nothing about whether the number is going anywhere,
/// and points are only worth caring about because they convert into a
/// captioned clip of your own battle. So this states the distance to that,
/// which also means a LOSS still visibly moves you forward - playing earns
/// points win or lose, and that is the retention job the currency exists
/// to do.
///
/// Renders nothing at zero: "0 points" is an argument against bothering.
class _PointsBalance extends StatefulWidget {
  const _PointsBalance({required this.balance});

  final num? balance;

  @override
  State<_PointsBalance> createState() => _PointsBalanceState();
}

/// A single spendable-reward milestone: the balance at which it becomes
/// affordable, an emoji that marks the spot, and a short name.
typedef _Reward = ({int price, String emoji, String label});

class _PointsBalanceState extends State<_PointsBalance> {
  /// Mirror the server defaults so the bar never renders wrong numbers and
  /// then corrects itself jarringly (functions/clipGrants.js and
  /// functions/points.js). Overwritten by config the moment it arrives.
  int _clipPrice = 500;
  int _dayPassPrice = 300;

  @override
  void initState() {
    super.initState();
    FirebaseFirestore.instance
        .collection('config')
        .doc('pointsSettings')
        .get()
        .then((snap) {
      final data = snap.data();
      final clip = (data?['clipPrice'] as num?)?.toInt();
      final pass = (data?['dayPassPrice'] as num?)?.toInt();
      if (!mounted) return;
      setState(() {
        if (clip != null && clip > 0) _clipPrice = clip;
        if (pass != null && pass > 0) _dayPassPrice = pass;
      });
    }).catchError((_) {
      // The defaults are fine answers; never block Home on this.
      return null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final balance = (widget.balance ?? 0).toInt();
    if (balance <= 0) return const SizedBox.shrink();

    final text = Theme.of(context).textTheme;
    // The things points buy, in price order. An emoji marks the exact
    // balance at which each becomes affordable.
    final rewards = <_Reward>[
      (price: _clipPrice, emoji: '🎬', label: 'clip'),
      (price: _dayPassPrice, emoji: '🎟️', label: 'day pass'),
    ]..sort((a, b) => a.price.compareTo(b.price));
    final scale = rewards.last.price.toDouble();

    // The next thing they cannot yet afford - the honest "keep going" line.
    _Reward? next;
    for (final r in rewards) {
      if (balance < r.price) {
        next = r;
        break;
      }
    }

    // Currency has its own themed token (money reads as money) and it is
    // deliberately NOT the rank gauge's colour, so a glance tells the two
    // bars apart - the top one is your RANK climbing, this is your WALLET
    // filling toward things to buy.
    final gold = context.palette.currency;
    final trackColor = Theme.of(context).colorScheme.surfaceContainerHighest;

    return Padding(
      padding: const EdgeInsets.fromLTRB(28, 6, 28, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '$balance points',
            textAlign: TextAlign.center,
            style: text.bodySmall?.copyWith(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          LayoutBuilder(
            builder: (context, constraints) {
              final w = constraints.maxWidth;
              const markerW = 36.0;
              // Emoji/price sit centred on their price point, clamped so an
              // end milestone never overflows the bar.
              double left(double frac) =>
                  (frac * w - markerW / 2).clamp(0.0, w - markerW);
              final fill = (balance / scale).clamp(0.0, 1.0);
              return SizedBox(
                height: 50,
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    // The emoji milestones, just above the track. Lit once
                    // affordable, dimmed until then.
                    for (final r in rewards)
                      Positioned(
                        left: left(r.price / scale),
                        top: 0,
                        width: markerW,
                        child: Opacity(
                          opacity: balance >= r.price ? 1.0 : 0.32,
                          child: Text(
                            r.emoji,
                            textAlign: TextAlign.center,
                            style: const TextStyle(fontSize: 19),
                          ),
                        ),
                      ),
                    // The wallet track + gold fill.
                    Positioned(
                      left: 0,
                      right: 0,
                      top: 26,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: Stack(
                          children: [
                            Container(
                                height: 6,
                                width: double.infinity,
                                color: trackColor),
                            FractionallySizedBox(
                              widthFactor: fill,
                              child: Container(height: 6, color: gold),
                            ),
                          ],
                        ),
                      ),
                    ),
                    // The price under each milestone, gold once reached.
                    for (final r in rewards)
                      Positioned(
                        left: left(r.price / scale),
                        top: 34,
                        width: markerW,
                        child: Text(
                          '${r.price}',
                          textAlign: TextAlign.center,
                          style: text.labelSmall?.copyWith(
                            color: balance >= r.price ? gold : null,
                            fontWeight: balance >= r.price
                                ? FontWeight.bold
                                : null,
                          ),
                        ),
                      ),
                  ],
                ),
              );
            },
          ),
          const SizedBox(height: 8),
          Text(
            next == null
                ? 'You can afford anything here - go spend it.'
                : '${next.price - balance} more for a ${next.label} ${next.emoji}',
            textAlign: TextAlign.center,
            style: text.bodySmall,
          ),
        ],
      ),
    );
  }
}

/// Explains why a battle isn't available, and what to do instead.
///
/// Deliberately never a dead end. Practice being closed during the window
/// points at Ranked, which is free for everyone right then; being lapsed
/// outside the window points at the window, which is free tonight. Both
/// are real alternatives available today, not just a subscribe button - a
/// paywall with no free path is how an app teaches people to close it.
Future<void> _showBlockedSheet(
    BuildContext context, Entitlement entitlement, String mode) {
  final windowName = entitlement.windowName ?? 'the daily window';
  final practiceDuringWindow = mode != 'ranked' && entitlement.inWindow;
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) => Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            practiceDuringWindow ? '$windowName is live' : 'Battle any time',
            style: Theme.of(sheetContext).textTheme.headlineSmall,
          ),
          const SizedBox(height: 8),
          Text(
            entitlement.blockedMessage ??
                'The nightly $windowName tournament is free, every night. '
                    'Subscribe to battle whenever you like.',
            style: Theme.of(sheetContext).textTheme.bodyMedium,
          ),
          const SizedBox(height: 24),
          if (practiceDuringWindow)
            FilledButton(
              onPressed: () {
                Navigator.of(sheetContext).pop();
                _startMatch(context, 'ranked');
              },
              child: const Text('Battle in the window instead'),
            )
          else ...[
            // THE HIGHEST-INTENT MOMENT IN THE APP for this offer: they
            // just tried to battle and were refused, so a day of anytime
            // battling is worth more to them right now than at any other
            // point. It is also the sample that makes the subscription
            // legible - you cannot want what you have never had.
            const _DayPassOffer(),
            FilledButton(
              // Still nothing to SELL - there is no IAP and no Play
              // Console account, so promising a purchase flow would be a
              // lie. Says plainly when they can play for free instead.
              onPressed: () => Navigator.of(sheetContext).pop(),
              child: const Text('Got it'),
            ),
          ],
          const SizedBox(height: 8),
          // Always available, whatever the tier or the hour, because it
          // costs nothing to provide. It is what stops this sheet being a
          // dead end for someone who cannot battle right now.
          TextButton(
            onPressed: () {
              Navigator.of(sheetContext).pop();
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => const SoloPracticeScreen(),
                ),
              );
            },
            child: const Text('Warm up solo instead'),
          ),
          TextButton(
            onPressed: () => Navigator.of(sheetContext).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    ),
  );
}

/// Shows the onboarding tutorial if this player hasn't done it, and
/// reports whether it's safe to continue into a match.
///
/// Fails OPEN: if the flag can't be read, the match proceeds. Being unable
/// to reach Firestore for a moment shouldn't stop someone playing, and the
/// cost of occasionally skipping the tutorial is far lower than the cost
/// of blocking matches on a transient read.
Future<bool> _ensureTutorialCompleted(BuildContext context) async {
  final uid = FirebaseAuth.instance.currentUser?.uid;
  if (uid == null) return true;
  try {
    final snap = await FirebaseFirestore.instance
        .collection('users')
        .doc(uid)
        .get();
    if (snap.data()?['tutorialCompleted'] == true) return true;
  } catch (_) {
    return true;
  }
  if (!context.mounted) return false;
  // Only continue into the match if they actually finished it.
  final completed = await Navigator.of(
    context,
  ).push<bool>(MaterialPageRoute(builder: (_) => const TutorialScreen()));
  return completed == true;
}

/// Shows the Laugh Meter (rank title + XP climb) and the win/loss record.
/// As of the XP ladder (2026-08-25) the title comes from career XP and the
/// Elo rating is hidden - it is not shown here or anywhere else.
///
/// Shows real progress rather than a silent unlock - that decision is
/// explicit, and a disabled button with no explanation reads as a bug.
/// The server enforces the gate regardless; this is the honest UI for it.
/// Shows a way back into a match the player was paired into but never
/// collected, and renders nothing at all when there isn't one.
///
/// This exists because of the match-found push: a player can be paired
/// while the app is backgrounded, and if the process was killed before
/// they came back, they'd otherwise land here with a live pairing they
/// have no route to. Their queue entry stays flagged "matched"
/// server-side precisely so it can be recovered (matched entries are
/// deliberately exempt from stale-entry pruning).
///
/// Re-checks on app resume as well as on first build, so tapping the
/// notification surfaces the banner even when the process was already
/// alive. Doubles as the in-app "match found" indicator CLAUDE.md asks
/// for alongside the push, though only in this recovery position - a
/// live indicator while queueing isn't built.
/// "Battle any time today for N points" - the points economy's recurring
/// sink, offered at the moment it is worth most.
///
/// WHY THIS SINK AND NOT MORE CLIPS. A clip is terminal: you want one, you
/// get it, and then you want nothing, so points go dead once someone has
/// covered the win they cared about. Access recurs - you want another next
/// week - so the grind never runs out of purpose. It is also the one thing
/// a free player most wants and cannot otherwise have, which makes
/// grinding for it a taste of the subscription rather than a substitute
/// for it.
///
/// Renders NOTHING unless a pass can actually be bought right now. An
/// offer someone cannot take is worse than no offer: it is a paywall with
/// a price tag they cannot reach, at the exact moment they were already
/// told no.
class _DayPassOffer extends StatefulWidget {
  const _DayPassOffer();

  @override
  State<_DayPassOffer> createState() => _DayPassOfferState();
}

class _DayPassOfferState extends State<_DayPassOffer> {
  Map<String, dynamic>? _state;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await FirebaseFunctions.instance
          .httpsCallable('getDayPassState')
          .call<Map<String, dynamic>>();
      if (mounted) setState(() => _state = r.data);
    } catch (_) {
      // Nothing rather than an error - the sheet still works without it.
    }
  }

  Future<void> _buy() async {
    setState(() => _busy = true);
    try {
      await FirebaseFunctions.instance
          .httpsCallable('buyDayPass')
          .call<Map<String, dynamic>>();
      if (!mounted) return;
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Day pass active. Battle whatever you like today.'),
        ),
      );
    } on FirebaseFunctionsException catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.message ?? 'Could not buy a pass.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = _state;
    if (state == null) return const SizedBox.shrink();
    final price = (state['price'] as num?)?.toInt() ?? 0;
    final balance = (state['balance'] as num?)?.toInt() ?? 0;
    final text = Theme.of(context).textTheme;

    // Switched off entirely from config - show nothing at all, including
    // the "N more points" nudge, or we would be advertising something
    // nobody can ever buy.
    if (state['enabled'] == false) return const SizedBox.shrink();

    if (state['canBuy'] != true) {
      // Short of the price, we show the GAP rather than nothing, because a
      // visible target is the whole reason to keep earning. Already bought
      // or already running shows nothing - there is nothing to offer.
      if (state['active'] == true || state['boughtToday'] == true ||
          balance >= price) {
        return const SizedBox.shrink();
      }
      return Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Text(
          '${price - balance} more points and you could battle any time '
          'for a day.',
          style: text.bodySmall,
          textAlign: TextAlign.center,
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          FilledButton.tonal(
            onPressed: _busy ? null : _buy,
            child: Text('Battle any time today - $price points'),
          ),
          const SizedBox(height: 4),
          Text(
            'You have $balance. One pass per day.',
            style: text.bodySmall,
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

/// "X challenged you" on Home.
///
/// A challenge expires in an hour, so it has to be visible somewhere the
/// player already looks - the push can be missed, muted, or denied at the
/// permission prompt, and a challenge nobody notices is the same as one
/// never sent. Renders nothing when there is none, so it costs a
/// zero-height widget the rest of the time.
class _IncomingChallengeBanner extends StatefulWidget {
  const _IncomingChallengeBanner();

  @override
  State<_IncomingChallengeBanner> createState() =>
      _IncomingChallengeBannerState();
}

class _IncomingChallengeBannerState extends State<_IncomingChallengeBanner>
    with WidgetsBindingObserver {
  Map<String, dynamic>? _challenge;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
    // POLL, not just load-once. This banner lives on Home, which sits in
    // MainShell's IndexedStack and is built ONCE at login - it never re-inits
    // when you switch tabs. So a challenge that arrives while you're already
    // in the app (foreground, on Home) was invisible until a full relaunch:
    // there's no resume event and no rebuild to trigger a reload, and the push
    // is best-effort (it may not fire at all). Found on a 2-device test
    // (2026-09-01). Friend battles are "battle now?", so the target has to see
    // it live. Mirrors the challenger's poll in challenge_screen.dart. Cheap at
    // beta scale - one callable every few seconds; revisit if it ever needs to
    // scale (a listener would be lighter, but challenges are callable-only).
    _poll = Timer.periodic(const Duration(seconds: 6), (_) {
      if (mounted) _load();
    });
  }

  @override
  void dispose() {
    _poll?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Re-checked on resume too (e.g. tapping the push notification brings the
    // app forward); the poll above covers the already-foreground case.
    if (state == AppLifecycleState.resumed) _load();
  }

  Future<void> _load() async {
    try {
      final r = await FirebaseFunctions.instance
          .httpsCallable('getMyChallenges')
          .call<Map<String, dynamic>>();
      final incoming = (r.data['incoming'] as List?) ?? const [];
      if (!mounted) return;
      setState(() => _challenge = incoming.isEmpty
          ? null
          : (incoming.first as Map).cast<String, dynamic>());
    } catch (_) {
      // Nothing rather than an error: a failed check must not make Home
      // look broken.
    }
  }

  @override
  Widget build(BuildContext context) {
    final challenge = _challenge;
    if (challenge == null) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: scheme.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '${challenge['fromUsername']} challenged you',
              style: Theme.of(context)
                  .textTheme
                  .titleSmall
                  ?.copyWith(color: scheme.onPrimaryContainer),
            ),
            const SizedBox(height: 8),
            FilledButton(
              onPressed: () async {
                await Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const ChallengeScreen()),
                );
                if (mounted) _load();
              },
              child: const Text('Answer'),
            ),
          ],
        ),
      ),
    );
  }
}

class _ActiveMatchBanner extends StatefulWidget {
  const _ActiveMatchBanner();

  @override
  State<_ActiveMatchBanner> createState() => _ActiveMatchBannerState();
}

class _ActiveMatchBannerState extends State<_ActiveMatchBanner>
    with WidgetsBindingObserver {
  final _service = MatchmakingService();
  MatchPairing? _pending;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _check();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _check();
  }

  Future<void> _check() async {
    final pairing = await _service.activeMatch();
    if (!mounted) return;
    setState(() => _pending = pairing);
  }

  void _rejoin() {
    final pairing = _pending;
    if (pairing == null) return;
    setState(() => _pending = null);
    Navigator.of(context)
        .push(
          MaterialPageRoute(builder: (_) => BioRevealScreen(pairing: pairing)),
        )
        // The match may have ended while they were away, so re-check on
        // the way back rather than leaving a stale banner behind.
        .then((_) => _check());
  }

  @override
  Widget build(BuildContext context) {
    if (_pending == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Card(
        color: Theme.of(context).colorScheme.primaryContainer,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            children: [
              // Someone who left a standing challenge may have queued
              // hours ago and forgotten. "You have a match waiting" reads
              // as a bug to them; naming what happened reads as the thing
              // they actually asked for.
              Text(
                _pending?.origin == 'standing'
                    ? 'Someone took up your challenge'
                    : 'You have a match waiting',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              FilledButton(
                onPressed: _rejoin,
                child: Text(
                  _pending?.origin == 'standing' ? 'Battle now' : 'Rejoin match',
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RankBadge extends StatelessWidget {
  const _RankBadge({required this.uid});

  final String uid;

  @override
  Widget build(BuildContext context) {
    final userRef = FirebaseFirestore.instance.collection('users').doc(uid);
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: userRef.snapshots(),
      builder: (context, snapshot) {
        if (!snapshot.hasData || !snapshot.data!.exists) {
          return const SizedBox.shrink();
        }
        final data = snapshot.data!.data()!;
        // Handed to the meter so a failed or slow gauge still shows who
        // the player is. This document is already streamed here.
        final rankTitle = data['rankTitle'] as String?;
        final wins = data['wins'] as num? ?? 0;
        final losses = data['losses'] as num? ?? 0;
        final username = data['username'] as String? ?? 'You';
        final points = data['points'] as num? ?? 0;

        // The rank card is a COLLECTIBLE PLAYER CARD (the reason the Card
        // look was chosen): tap it and it flips to a trophy back with your
        // record, win rate and career points - the shareable face. Only
        // the framed skins have a card to turn over; plainer skins show
        // the meter as before. This is deliberately YOUR OWN card only -
        // flipping other people's cards to reveal their stats/bio would
        // walk back the "opponent rank hidden pre-match" and directory-
        // privacy decisions (see CLAUDE.md).
        final meter = LaughMeter(fallbackTitle: rankTitle);
        final hasCard = context.palette.signature == 'frame';
        return Column(
          children: [
            // The Laugh Meter carries the rank title and the climb toward
            // the next one - now the climb is XP, not Elo. As of the XP
            // ladder (2026-08-25) the Elo rating is hidden EVERYWHERE (it
            // only runs matchmaking underneath); it is no longer shown here
            // or in the profile stats.
            if (hasCard)
              _FlipRankCard(
                front: meter,
                back: _RankCardBack(
                  username: username,
                  title: rankTitle,
                  wins: wins,
                  losses: losses,
                  points: points,
                ),
              )
            else
              meter,
            const SizedBox(height: 8),
            // ONE line, not three. This block had the record, a points
            // total and a second progress bar stacked under the gauge -
            // four rows of small grey text and two near-identical amber
            // bars, which read as a wall of status rather than as an
            // identity. The points progress moved down to sit with the
            // quests, where everything else about earning lives.
            Text(
              '$wins-$losses',
              style: Theme.of(context).textTheme.labelSmall,
            ),
            // Shown right under a rating that can fall, deliberately. This
            // is the number that only ever climbs, so a player on a losing
            // streak still has something going up next to something going
            // down - which is the reason the currency exists at all.
            // Shown right under a rating that can fall, deliberately, and
            // shown as progress toward something REAL rather than as a
            // bare count or an abstract title.
            //
            // A second ladder of point-earned titles was built here and
            // removed: rank is the app's one status system, and a
            // competing set of titles diluted it for the player and
            // doubled the tuning for the developer. What survives is the
            // part that was actually doing the work - a loss still earns
            // points, so it still moves you toward a clip you can post.
            // That beats a title because it converts into something.
          ],
        );
      },
    );
  }
}

/// Tap-to-flip wrapper for the rank card. Renders [front] and [back] as the
/// two faces of one card that rotates around its vertical axis on tap.
///
/// Both faces are kept mounted in a Stack sized to the front, so the layout
/// height never jumps mid-flip (the swap happens at 90 degrees, when the
/// card is edge-on and invisible anyway). The back is pre-rotated 180 so it
/// is not mirror-imaged once it faces the viewer.
class _FlipRankCard extends StatefulWidget {
  const _FlipRankCard({required this.front, required this.back});

  final Widget front;
  final Widget back;

  @override
  State<_FlipRankCard> createState() => _FlipRankCardState();
}

class _FlipRankCardState extends State<_FlipRankCard>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 460),
  );
  bool _showBack = false;

  void _flip() {
    setState(() => _showBack = !_showBack);
    _showBack ? _c.forward() : _c.reverse();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      // Opaque so a tap anywhere over the card - including the transparent
      // margin around the framed panel - turns it.
      behavior: HitTestBehavior.opaque,
      onTap: _flip,
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, _) {
          final t = _c.value;
          final frontUp = t < 0.5;
          return Transform(
            alignment: Alignment.center,
            transform: Matrix4.identity()
              ..setEntry(3, 2, 0.0012)
              ..rotateY(t * math.pi),
            child: Stack(
              children: [
                Opacity(opacity: frontUp ? 1 : 0, child: widget.front),
                Positioned.fill(
                  child: Opacity(
                    opacity: frontUp ? 0 : 1,
                    child: Transform(
                      alignment: Alignment.center,
                      transform: Matrix4.identity()..rotateY(math.pi),
                      child: widget.back,
                    ),
                  ),
                ),
                // A quiet hint that the card turns, shown only on the front.
                if (frontUp)
                  Positioned(
                    top: 4,
                    right: 28,
                    child: Opacity(
                      opacity: 0.45,
                      child: Icon(Icons.flip_camera_android_outlined,
                          size: 15, color: scheme.onSurface),
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// The back of the rank card - a shareable "player card" trophy face: the
/// username, the earned title, and the three stats a player would screenshot
/// (record, win rate, career points). Matches the LaughMeter's framed panel
/// so it reads as the same card turned over.
class _RankCardBack extends StatelessWidget {
  const _RankCardBack({
    required this.username,
    required this.title,
    required this.wins,
    required this.losses,
    required this.points,
  });

  final String username;
  final String? title;
  final num wins;
  final num losses;
  final num points;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final total = wins + losses;
    final winRate = total > 0 ? ((wins / total) * 100).round() : 0;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 20),
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 18),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: context.palette.accent, width: 1.5),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            context.palette.accent.withValues(alpha: 0.10),
            scheme.surfaceContainer,
            context.palette.gelB.withValues(alpha: 0.10),
          ],
        ),
      ),
      // FittedBox guards against overflow: the back is sized to match the
      // front card (Positioned.fill in the flip), and the front's height
      // varies with the rank title and the gauge state, so the trophy
      // content scales down to fit rather than overflowing a tight box.
      child: Center(
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                username,
                style:
                    text.headlineSmall?.copyWith(fontWeight: FontWeight.bold),
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              if (title != null) ...[
                const SizedBox(height: 2),
                Text(title!,
                    style: text.bodySmall, textAlign: TextAlign.center),
              ],
              const SizedBox(height: 16),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _stat(context, '$wins-$losses', 'RECORD'),
                  const SizedBox(width: 22),
                  _stat(context, '$winRate%', 'WIN RATE'),
                  const SizedBox(width: 22),
                  _stat(context, '$points', 'CAREER'),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _stat(BuildContext context, String value, String label) {
    final text = Theme.of(context).textTheme;
    return Column(
      children: [
        Text(
          value,
          style: text.titleLarge?.copyWith(
            fontWeight: FontWeight.bold,
            color: context.palette.accent,
          ),
        ),
        const SizedBox(height: 2),
        Text(label,
            style: text.bodySmall?.copyWith(letterSpacing: 0.5)),
      ],
    );
  }
}

/// The points balance, streamed for one user.
///
/// Split out because the balance moved OUT of the identity block and
/// down beside the quests, away from the stream _RankBadge already had.
/// Grouping it with the quests is the point: everything about what you
/// can earn today now sits together, instead of a second progress bar
/// competing with the rank gauge for the same glance.
class _PointsBalanceForUser extends StatelessWidget {
  const _PointsBalanceForUser({required this.uid});

  final String uid;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .snapshots(),
      builder: (context, snapshot) {
        final data = snapshot.data?.data();
        if (data == null) return const SizedBox.shrink();
        return _PointsBalance(
          balance: (data['pointsBalance'] ?? data['points']) as num?,
        );
      },
    );
  }
}

