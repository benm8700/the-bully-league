import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
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
import '../practice/solo_practice_screen.dart';
import '../settings/notification_settings_screen.dart';
import '../support/support_screen.dart';
import '../directory/player_search_screen.dart';
import '../tournament/tournament_list_screen.dart';
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
          // The help icon is where people look when they are confused, so
          // it offers both things a confused person might want: a reminder
          // of how a battle actually works, and a way to reach a human.
          //
          // The tutorial was previously UNREACHABLE after the first time -
          // completing it set a flag and nothing ever offered it again, so
          // anyone who wanted to check the rules had no way back to them.
          // Replaying costs nothing: it uses the local camera preview and
          // a simulated opponent, joining no channel and burning no video
          // minutes.
          PopupMenuButton<String>(
            icon: const Icon(Icons.help_outline),
            tooltip: 'Help',
            onSelected: (choice) {
              final route = choice == 'tutorial'
                  ? MaterialPageRoute<void>(
                      builder: (_) => const TutorialScreen(replay: true),
                    )
                  : MaterialPageRoute<void>(
                      builder: (_) => const SupportScreen(),
                    );
              Navigator.of(context).push(route);
            },
            itemBuilder: (context) => const [
              PopupMenuItem(
                value: 'tutorial',
                child: Text('How a battle works'),
              ),
              PopupMenuItem(
                value: 'support',
                child: Text('Support & feedback'),
              ),
            ],
          ),
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
                    Text(
                      'Welcome, $username',
                      style: Theme.of(context).textTheme.headlineMedium,
                    ),
                    const SizedBox(height: 12),
                    if (uid != null) _RankBadge(uid: uid),
                    const SizedBox(height: 24),
                    const _ActiveMatchBanner(),
                    const EventWindowBanner(),
                    const DailyQuests(),
                    const _TrialStatus(),
                    const SizedBox(height: 4),
                    // Ranked is available immediately - the unlock gate is
                    // gone (see CLAUDE.md's Modes section). The tutorial
                    // already covers the mechanics, and under the
                    // monetization model a free player's only battling is
                    // ranked during the window, so a practice-first gate
                    // would lock them out of the one thing they get.
                    FilledButton(
                      onPressed: () => _startMatch(context, 'ranked'),
                      child: const Text('Find Ranked Match'),
                    ),
                    // Ranked is the primary action and Practice is
                    // deliberately quieter. Everything durable lives in
                    // ranked - it is the only recorded mode, so the only
                    // one producing clips, feed content and a ladder
                    // position - and offering both as equal siblings split
                    // an already-thin pool across two queues.
                    //
                    // Named "Practice" rather than "Exhibition" because
                    // the people who need it are new, and "exhibition"
                    // tells them nothing about what it is for. The
                    // internal mode id stays `exhibition`: renaming that
                    // would orphan every existing queue entry, match
                    // document and unlock counter.
                    const SizedBox(height: 8),
                    TextButton(
                      onPressed: () => _startMatch(context, 'exhibition'),
                      child: const Text('Practice instead'),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 32),
                      child: Text(
                        'Unranked and never recorded. Good for checking your '
                        'camera and lighting, or getting the first one out of '
                        'the way.',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                    const SizedBox(height: 12),
                    // Quieter still than Practice, and free at every tier
                    // because it costs the platform nothing - no channel is
                    // joined, so no Agora minutes are billed. Its real job
                    // is the empty-pool case: someone who opens the app when
                    // nobody is online needs something to do that is not a
                    // consolation prize.
                    TextButton(
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => const SoloPracticeScreen(),
                        ),
                      ),
                      child: const Text('Warm up solo'),
                    ),
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
                    OutlinedButton(
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => const PlayerSearchScreen(),
                        ),
                      ),
                      child: const Text('Find a Player'),
                    ),
                    const SizedBox(height: 12),
                    OutlinedButton(
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => const TournamentListScreen(),
                        ),
                      ),
                      child: const Text('Tournaments'),
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
          ? 'Last day of full access. After that, ranked stays free during '
              '$windowName.'
          : '$daysLeft days of full access left.';
    } else {
      message = e.inWindow
          ? '$windowName is live - ranked is free right now.'
          : 'Ranked is free every night during $windowName.';
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

class _PointsBalanceState extends State<_PointsBalance> {
  /// Mirrors DEFAULT_CLIP_POINTS_PRICE in functions/clipGrants.js, used
  /// until the live value arrives so the line never renders a wrong number
  /// and then corrects itself jarringly.
  int _clipPrice = 250;

  @override
  void initState() {
    super.initState();
    FirebaseFirestore.instance
        .collection('config')
        .doc('pointsSettings')
        .get()
        .then((snap) {
      final price = (snap.data()?['clipPrice'] as num?)?.toInt();
      if (mounted && price != null && price > 0) {
        setState(() => _clipPrice = price);
      }
    }).catchError((_) {
      // The default is a fine answer; never block Home on this.
      return null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final balance = (widget.balance ?? 0).toInt();
    if (balance <= 0) return const SizedBox.shrink();

    final enough = balance >= _clipPrice;
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 6, 32, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '$balance points',
            textAlign: TextAlign.center,
            style: text.bodySmall?.copyWith(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 4),
          if (!enough)
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: balance / _clipPrice,
                minHeight: 5,
              ),
            ),
          const SizedBox(height: 4),
          Text(
            enough
                ? 'Enough for the captioned cut of one of your battles.'
                : '${_clipPrice - balance} more for the captioned cut of one '
                    'of your battles.',
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
                'Ranked is free every night during $windowName. '
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
              child: const Text('Battle ranked instead'),
            )
          else
            FilledButton(
              // Nothing to sell yet - there is no IAP and no Play Console
              // account, so promising a purchase flow would be a lie.
              // Says plainly when they can play for free instead.
              onPressed: () => Navigator.of(sheetContext).pop(),
              child: const Text('Got it'),
            ),
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

/// Shows rank title + raw rating + win/loss record. Real "Laugh Meter"
/// visual gauge (CLAUDE.md's Display decision) isn't designed yet - this is
/// the plain "detailed stats view" fallback CLAUDE.md explicitly allows.
/// The Ranked entry point, which stays locked until a few exhibition
/// matches are done (CLAUDE.md's Modes decision).
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
        final rankTitle = data['rankTitle'] as String? ?? 'Average Joe';
        final rating = data['rating'] as num? ?? 1200;
        final wins = data['wins'] as num? ?? 0;
        final losses = data['losses'] as num? ?? 0;
        return Column(
          children: [
            Text(rankTitle, style: Theme.of(context).textTheme.titleLarge),
            Text(
              'Rating: $rating',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            Text(
              '$wins wins, $losses losses',
              style: Theme.of(context).textTheme.bodySmall,
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
            _PointsBalance(
              balance: (data['pointsBalance'] ?? data['points']) as num?,
            ),
          ],
        );
      },
    );
  }
}
