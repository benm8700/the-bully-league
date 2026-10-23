import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import 'package:provider/provider.dart';

import '../../theme/app_theme.dart';
import '../rewards/rewards_screen.dart';

import '../../core/services/auth_service.dart';
import '../../core/services/entitlement_service.dart';
import '../../core/services/matchmaking_service.dart';
import '../../widgets/admin_only.dart';
import '../../widgets/home/goat_throne_banner.dart';
import '../../widgets/home/main_stage_banner.dart';
import '../../widgets/home/prize_claim_banner.dart';
import '../../widgets/home/hero_mode_card.dart';
import '../../widgets/home/player_status_card.dart';
import '../../widgets/home/home_quick_actions.dart';
import '../../widgets/home/home_featured.dart';
import '../../widgets/home/main_stage_card.dart';
import '../../widgets/home/daily_window_strip.dart';
import 'main_shell.dart';
import '../match/bio_reveal_screen.dart';
import '../match/improv_match_screen.dart';
import '../match/matchmaking_screen.dart';
import '../match/pre_match_screen.dart';
import '../match/recording_consent_screen.dart';
import '../profile/profile_screen.dart';
import '../friends/challenge_screen.dart';
import '../practice/solo_practice_screen.dart';
import '../settings/account_screen.dart';
import '../settings/notification_settings_screen.dart';
import '../vote/finalize_test_screen.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final authService = context.read<AuthService>();

    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        // The header logo is the WORDMARK-ONLY branding asset
        // (assets/branding/bully_league_wordmark.png) - the approved
        // bully_league_header.png with the "REAL PEOPLE. REAL ROASTS." tagline
        // cropped off (developer's call, 2026-09-14). The full header PNG is
        // kept in the repo untouched; this is a separate cropped file, so
        // restoring the tagline is a one-line asset-path change. Sized by
        // height only (BoxFit.contain preserves the aspect ratio - never
        // stretched, cropped or recoloured), kept compact.
        toolbarHeight: 72,
        titleSpacing: 16,
        title: Align(
          alignment: Alignment.centerLeft,
          child: Image.asset(
            'assets/branding/bully_league_wordmark.png',
            height: 44,
            fit: BoxFit.contain,
          ),
        ),
        actions: [
          // The bell shows notification settings (no badge count).
          IconButton(
            icon: const Icon(Icons.notifications_outlined),
            tooltip: 'Notifications',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => const NotificationSettingsScreen(),
              ),
            ),
          ),
          // The profile avatar opens ACCOUNT & SETTINGS - deliberately NOT
          // the public Profile tab, which is the player's public identity.
          // (Sign out used to be a top-right one-tap button that a real user
          // hit by accident; it now lives one level in, inside Account.)
          Padding(
            padding: const EdgeInsets.only(right: 12, left: 4),
            child: Tooltip(
              message: 'Account',
              child: InkResponse(
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const AccountScreen()),
                ),
                child: CircleAvatar(
                  radius: 16,
                  backgroundColor: scheme.surfaceContainerHighest,
                  child: Icon(Icons.person,
                      size: 18, color: scheme.onSurfaceVariant),
                ),
              ),
            ),
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
          final uid = snapshot.data?.uid;
          // Scrollable rather than a bare centred Column: Home has grown
          // past what a small screen can show at once (seen live as a
          // 156px overflow on a 320x640 device), and it will keep growing.
          // Centred only when there's room to spare, so it still looks
          // deliberate on a large phone rather than pinned to the top.
          // The system gesture/nav bar inset at the bottom. Without adding it
          // to the scroll padding, when the content height is close to the
          // viewport height (seen on the S22) the centred Column sits its
          // bottom items - the Find a Match CTA - flush against the nav bar
          // with no room to scroll clear of it.
          final bottomInset = MediaQuery.of(context).viewPadding.bottom;
          return LayoutBuilder(
            builder: (context, constraints) => SingleChildScrollView(
              padding: EdgeInsets.only(top: 16, bottom: 16 + bottomInset),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  minHeight: constraints.maxHeight - 32 - bottomInset,
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    // The Player Status card IS the identity block now - the
                    // old username greeting above it was redundant furniture
                    // (the name is on the card's trophy context and the
                    // header carries the brand), so it was removed in the
                    // 2026-09-14 Home overhaul to match the reference.
                    if (uid != null) _RankBadge(uid: uid),
                    // Tightened so the compact HUD sits closer to the Tournament
                    // hero, leaving a little more of Roast a Stranger visible.
                    const SizedBox(height: 12),
                    // Anything urgent stays at the very top: a match
                    // waiting, or somebody challenging you.
                    const _ActiveMatchBanner(),
                    const _IncomingChallengeBanner(),
                    // When you're in this week's finals (finalist/alternate/
                    // judge), the front door to the Main Stage - confirm your
                    // spot, make your callout. Nothing otherwise.
                    const MainStageBanner(),
                    const PrizeClaimBanner(),
                    // The "defend your throne" warning - shown only to a GOAT
                    // under threat or the challenger closing on their spot.
                    const GoatThroneBanner(),
                    const _TrialStatus(),
                    const SizedBox(height: 8),
                    // The daily 6-7pm "power hour" (2x points) sits ABOVE the
                    // Basement hero - the multiplier is for everyday Basement
                    // play, so it headlines that block. Renders nothing when
                    // the window is switched off (its own bottom padding spaces
                    // it from the hero below).
                    const DailyWindowStrip(),
                    // TWO FRONT DOORS: PLAY / WATCH (Home redesign,
                    // 2026-10-22). The old Home stacked four mode heroes
                    // (Basement, Main Stage, Friend, Face-Off) which read as a
                    // confusing wall of categories to a newcomer. The one
                    // decision anyone understands is "make it" vs "watch it", so
                    // that owns the screen: PLAY -> roast a stranger (the
                    // everyday Basement battle), WATCH -> the Vote feed. The
                    // modes and their wiring are untouched - this is just the
                    // front door.
                    const _PlayWatchDoors(),
                    const SizedBox(height: 14),
                    // The WEEKLY Main Stage tournament stays its own distinct
                    // card - it is the EVENT/destination, not an everyday mode,
                    // so it earns a spot below the doors rather than hiding
                    // under "more ways to play". Taps to the hub.
                    const MainStageCard(),
                    const SizedBox(height: 12),
                    // The other two ways to play, demoted to a compact secondary
                    // row so they are reachable without crowding the two doors:
                    // Face-Off (improv) and Challenge a Friend.
                    const _MoreWaysToPlay(),
                    const SizedBox(height: 14),
                    // Quick Actions row (Home overhaul): Daily Challenges /
                    // Free Rewards / Current Streak. The Daily Challenges card
                    // opens the full quests in a sheet, so the tall inline
                    // quest list is no longer shown here (one route, not two).
                    if (uid != null) HomeQuickActions(uid: uid),
                    const SizedBox(height: 14),
                    // Slim wallet line: "N Points" + Rewards ->. The old
                    // milestone bar moved into the Rewards screen; Home keeps
                    // only the glanceable balance and a way in.
                    if (uid != null) _WalletBarForUser(uid: uid),
                    // Featured spotlight - the founder's Editor's Choice picks,
                    // streamed live from the `featured` collection. Renders
                    // NOTHING when there are no picks (empty/loading/error), so
                    // it never leaves a broken-looking gap. See HomeFeatured /
                    // FeaturedSection.
                    const HomeFeatured(),
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
                    // Battle a Friend is now a FEATURED hero pill up top (under
                    // the two mode heroes), not a quiet nav-list card - so it is
                    // deliberately not repeated down here.
                    //
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
                    // "How it works" moved off Home into Account & Settings
                    // (the top-right profile icon), under the account/email.
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
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
/// Runs [future] behind a non-dismissible spinner, so a tap that kicks off a
/// (possibly cold) Cloud Function call gives immediate feedback and can't be
/// double-fired while it's in flight. Pops the spinner when done.
Future<T?> _withSpinner<T>(BuildContext context, Future<T> future) async {
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => const Center(child: CircularProgressIndicator()),
  );
  try {
    return await future;
  } finally {
    if (context.mounted) Navigator.of(context, rootNavigator: true).pop();
  }
}

Future<void> _startMatch(BuildContext context, String mode) async {
  // Asked FIRST, before anything that costs the player effort. Without
  // this a lapsed player sits through the tutorial gate, the recording
  // consent screen and the entire camera-and-mic check, and only then gets
  // turned away by the queue - the worst possible moment to say no, and it
  // reads as a bug rather than a price. The server still enforces; this
  // just turns a late refusal into an early offer.
  //
  // Shown behind a blocking spinner because this is a Cloud Function call and
  // the FIRST one after a cold app launch is slow - without feedback the first
  // tap looked completely dead and people tapped again (seen on both phones).
  // The modal barrier also stops a double-tap starting two flows at once.
  final entitlement = await _withSpinner(context, EntitlementService().current());
  if (entitlement == null || !context.mounted) return;
  if (!entitlement.allows(mode)) {
    await _showBlockedSheet(context, entitlement, mode);
    return;
  }

  // The one thing a player must do before a ranked/tournament battle is record
  // an intro video (the ammo the opponent studies, and the enterQueue gate) -
  // so if it's missing, route them straight to their profile to record it
  // rather than letting them walk to the queue and be refused. (The old
  // required text fields were cut 2026-10-17; the intro is the only gate.)
  if (!await _ensureIntroReady(context, mode)) return;
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

/// Makes sure the player is battle-ready before a ranked or tournament match:
/// an approved intro video AND the four required profile fields filled in.
///
/// This replaced the forced practice round. Two things must exist before a
/// real battle: the intro video (the ammo the opponent studies, and the
/// enterQueue gate) and a filled-in profile (the developer's call after
/// players entered ranked with blank profiles - the opponent gets nothing to
/// work with). When either is missing we send the player to their profile to
/// complete it rather than letting them reach the queue and hit a late
/// refusal. Practice (exhibition) is exempt: it's the warm-up, and a
/// first-timer should be able to practise before they've recorded anything.
///
/// Fails OPEN: if the doc can't be read, the match proceeds and the server's
/// own enterQueue gate has the final say - a transient read shouldn't block
/// someone who is actually ready.
Future<bool> _ensureIntroReady(BuildContext context, String mode) async {
  // Exhibition and IMPROV are exempt: improv riffs a prompt, not the opponent,
  // so there's no ammo to study (matches enterQueue's server-side exemption).
  if (mode == 'exhibition' || mode == 'improv') return true;
  final uid = FirebaseAuth.instance.currentUser?.uid;
  if (uid == null) return true;
  try {
    final snap = await FirebaseFirestore.instance
        .collection('users')
        .doc(uid)
        .get();
    final profile = snap.data()?['profile'] as Map<String, dynamic>?;
    final introUrl = profile?['introVideoUrl'] as String?;
    final hasIntro = introUrl != null && introUrl.isNotEmpty;
    // The intro video is the ONLY ranked requirement now - the structured
    // profile fields were cut (2026-10-17), so the gate no longer checks them.
    if (hasIntro) return true;
  } catch (_) {
    return true;
  }
  if (!context.mounted) return false;
  // Take them straight to where they record the intro and fill the fields,
  // with a banner explaining why. They'll tap battle again once ready.
  await Navigator.of(context).push(
    MaterialPageRoute(builder: (_) => const ProfileScreen(promptIntro: true)),
  );
  return false;
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
  bool _busy = false;

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
      // Only the INCOMING (unanswered) challenge belongs here - the acceptor's
      // "answer this" prompt. Rejoining a LIVE accepted battle is handled by
      // _ActiveMatchBanner, which keys off the match's own status so it
      // self-clears when the battle ends. (An earlier "accepted" banner here
      // keyed off the challenge, which never clears, so it lingered after the
      // battle was over and duplicated the active-match banner.)
      setState(() => _challenge = incoming.isEmpty
          ? null
          : (incoming.first as Map).cast<String, dynamic>());
    } catch (_) {
      // Nothing rather than an error: a failed check must not make Home
      // look broken.
    }
  }

  /// Accept the challenge and go STRAIGHT into the pre-match check - no detour
  /// through the full Challenge screen to tap Accept a second time. The banner
  /// already names who it is from, so one tap here is the whole decision.
  Future<void> _accept() async {
    final id = _challenge?['challengeId'] as String?;
    if (id == null || _busy) return;
    setState(() => _busy = true);
    try {
      final r = await FirebaseFunctions.instance
          .httpsCallable('respondToChallenge')
          .call<Map<String, dynamic>>({'challengeId': id, 'accept': true});
      final matchId = r.data['matchId'] as String?;
      if (!mounted) return;
      setState(() {
        _busy = false;
        _challenge = null; // clear it - it's answered
      });
      if (matchId != null) {
        await startChallengeMatch(context, matchId);
        if (mounted) _load();
      }
    } on FirebaseFunctionsException catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.message ?? 'Could not accept that.')),
      );
      _load();
    }
  }

  Future<void> _decline() async {
    final id = _challenge?['challengeId'] as String?;
    if (id == null || _busy) return;
    setState(() => _busy = true);
    try {
      await FirebaseFunctions.instance
          .httpsCallable('respondToChallenge')
          .call<Map<String, dynamic>>({'challengeId': id, 'accept': false});
    } catch (_) {
      // Best-effort; the reload below reflects the real state either way.
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _challenge = null;
    });
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final challenge = _challenge;
    if (challenge == null) return const SizedBox.shrink();
    return Card(
      color: scheme.surfaceContainerHigh,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.sports_mma, size: 18, color: scheme.secondary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '${challenge['fromUsername']} challenged you',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: FilledButton(
                    onPressed: _busy ? null : _accept,
                    child: Text(_busy ? 'Starting…' : 'Accept challenge'),
                  ),
                ),
                const SizedBox(width: 8),
                TextButton(
                  onPressed: _busy ? null : _decline,
                  child: const Text('Decline'),
                ),
              ],
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
  QueueStatus? _queued;
  Timer? _poll;
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _check();
    // A light 1s ticker so the "in the queue" banner's elapsed time counts up
    // smoothly between the 4s network polls. Local only - no network, and it
    // only repaints while that banner is actually showing.
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && _queued != null && _pending == null) setState(() {});
    });
    // POLL, not just initState + resume. Home lives in MainShell's
    // IndexedStack and is built ONCE, and backing out of pre-match/bio-reveal
    // is an in-app pop (not an app-lifecycle resume), so without a poll the
    // rejoin banner only caught up on the next app resume - the ~15s lag the
    // developer saw. getActiveMatch keys off the match's own status, so the
    // same poll makes the banner DISAPPEAR within a few seconds once the
    // battle completes or is abandoned (the stale-after-completion bug).
    _poll = Timer.periodic(const Duration(seconds: 4), (_) {
      if (mounted) _check();
    });
  }

  @override
  void dispose() {
    _poll?.cancel();
    _tick?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _check();
  }

  Future<void> _check() async {
    final status = await _service.activeStatus();
    if (!mounted) return;
    setState(() {
      _pending = status.pairing;
      _queued = status.queued;
    });
  }

  void _rejoin() {
    final pairing = _pending;
    if (pairing == null) return;
    setState(() => _pending = null);
    Navigator.of(context)
        .push(
          MaterialPageRoute(
            // Face-Off (improv) has no bio reveal - you riff a prompt, blind to
            // the opponent - so a rejoined improv pairing goes straight to its
            // own performance screen, same branch the matchmaking screen uses.
            // Without this, taking up a Face-Off standing challenge showed the
            // opponent-ammo page.
            builder: (_) => pairing.mode == 'improv'
                ? ImprovMatchScreen(pairing: pairing)
                : BioRevealScreen(pairing: pairing),
          ),
        )
        // The match may have ended while they were away, so re-check on
        // the way back rather than leaving a stale banner behind.
        .then((_) => _check());
  }

  /// Human label for a queue mode.
  static String _modeLabel(String mode) => switch (mode) {
        'improv' => 'Face-Off',
        'exhibition' => 'Practice',
        _ => 'Ranked',
      };

  /// Elapsed since joining the queue, compact: 45s, 3m, 1h 12m.
  static String _elapsed(int joinedAtMs) {
    final s = ((DateTime.now().millisecondsSinceEpoch - joinedAtMs) / 1000)
        .floor()
        .clamp(0, 1 << 30);
    if (s < 60) return '${s}s';
    final m = s ~/ 60;
    if (m < 60) return '${m}m';
    return '${m ~/ 60}h ${m % 60}m';
  }

  /// Returns to the search screen so they can keep waiting or cancel.
  void _resumeQueue() {
    final q = _queued;
    if (q == null) return;
    Navigator.of(context)
        .push(MaterialPageRoute(
          builder: (_) => MatchmakingScreen(mode: q.mode),
        ))
        .then((_) => _check());
  }

  /// A calm "you're in the queue" banner that counts up from when you joined,
  /// shown when there's no opponent yet (a rejoinable match takes priority).
  Widget _queueBanner(BuildContext context) {
    final q = _queued!;
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Material(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: _resumeQueue,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 13, 16, 14),
            child: Row(
              children: [
                SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(
                      strokeWidth: 2.5, color: scheme.primary),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'In the ${_modeLabel(q.mode)} queue · ${_elapsed(q.joinedAtMs)}',
                        style: TextStyle(
                            color: scheme.onSurface,
                            fontWeight: FontWeight.bold,
                            fontSize: 15),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        "Waiting for an opponent — we'll notify you.",
                        style: TextStyle(
                            color: scheme.onSurfaceVariant, fontSize: 12.5),
                      ),
                    ],
                  ),
                ),
                Icon(Icons.chevron_right, color: scheme.onSurfaceVariant),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_pending == null && _queued != null) return _queueBanner(context);
    if (_pending == null) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    // Deliberately LOUD and distinct from the neutral Home cards around it -
    // "you have a battle waiting RIGHT NOW" is the most time-sensitive thing
    // on the screen, and the old primaryContainer tint blended in. A solid
    // primary (brand pink) card with an icon and a high-contrast button reads
    // as an alert, not another option.
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Material(
        color: scheme.primary,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: _rejoin,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
            child: Row(
              children: [
                Icon(Icons.sports_mma, color: scheme.onPrimary, size: 28),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Someone who left a standing challenge may have queued
                      // hours ago and forgotten, so name what happened rather
                      // than announcing a generic match.
                      Text(
                        switch (_pending?.origin) {
                          'standing' => 'Someone took up your challenge',
                          'friend' => 'Your friend battle is ready',
                          _ => 'You have a match waiting',
                        },
                        style: TextStyle(
                          color: scheme.onPrimary,
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Tap to jump in',
                        style: TextStyle(
                          color: scheme.onPrimary.withValues(alpha: 0.85),
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: _rejoin,
                  // A deep warm-charcoal button with a warm-white label - dark
                  // on hot pink reads sharp and modern and meshes with the
                  // warm pink far better than white or gold (both rejected).
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF221015),
                    foregroundColor: const Color(0xFFFFF2F4),
                  ),
                  child: Text(
                    switch (_pending?.origin) {
                      'standing' => 'Battle now',
                      'friend' => 'Battle now',
                      _ => 'Rejoin',
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// One-click return to a live gauntlet you backed out of or crashed during.
///
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
        // Handed to the card so a failed or slow meter/rank query still
        // shows who the player is. This document is already streamed here.
        final rankTitle = data['rankTitle'] as String?;
        final points = data['points'] as num?;

        // The Home overhaul (2026-09-14) replaced the tap-to-flip
        // collectible card with a single horizontal PLAYER STATUS card:
        // tier + rank badge + XP progress on the left, GLOBAL RANK on the
        // right. This shows numbers (XP and position), a deliberate
        // softening of the hidden-criteria rule - the developer's call to
        // match the reference. The card degrades to the fallback title if
        // the meter/rank queries fail, so the identity never disappears.
        return PlayerStatusCard(
          uid: uid,
          fallbackTitle: rankTitle,
          fallbackPoints: points,
        );
      },
    );
  }
}

/// Streams the user's spendable balance for the Home wallet line.
class _WalletBarForUser extends StatelessWidget {
  const _WalletBarForUser({required this.uid});

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
        final balance =
            ((data['pointsBalance'] ?? data['points']) as num?)?.toInt() ?? 0;
        return _WalletBar(balance: balance);
      },
    );
  }
}

/// A slim wallet line: "N Points" on the left, "Rewards ->" on the right.
///
/// The whole strip taps through to the Rewards screen, where the milestone
/// list and redemption now live (the old Home milestone bar moved there).
class _WalletBar extends StatelessWidget {
  const _WalletBar({required this.balance});

  final int balance;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final gold = context.palette.currency;
    final accent = context.palette.accent;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Material(
        color: scheme.surfaceContainer,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const RewardsScreen()),
          ),
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: scheme.outlineVariant),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Row(
              children: [
                Icon(Icons.monetization_on, color: gold, size: 18),
                const SizedBox(width: 7),
                Text(
                  '$balance',
                  style: text.titleSmall?.copyWith(
                    fontWeight: FontWeight.w900,
                    color: gold,
                  ),
                ),
                const SizedBox(width: 4),
                Text(
                  'Points',
                  style: text.bodyMedium
                      ?.copyWith(color: scheme.onSurfaceVariant),
                ),
                const Spacer(),
                Text(
                  'Rewards',
                  style: text.labelLarge?.copyWith(
                    color: accent,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(width: 2),
                Icon(Icons.arrow_forward, color: accent, size: 16),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The two front doors: PLAY and WATCH, as the premium pillbox hero cards used
/// elsewhere on Home.
///
/// This is the whole point of the Home redesign - the first decision a visitor
/// makes is reduced to the two things anyone understands (make it vs watch it)
/// instead of a wall of named modes. PLAY launches the everyday Basement battle
/// (roast a stranger) through the existing _startMatch path, so the entitlement
/// gate and the rest of the flow are untouched. WATCH jumps to the Vote tab.
///
/// The art carries the words (the developer bakes "PLAY"/"WATCH" into the PNGs),
/// so nothing is overlaid. Play reuses the Basement art (assets/home/roast_hero.png)
/// for a good look out of the box; Watch uses assets/home/watch_hero.png (a
/// re-lettered copy of the Main Stage art) and shows a plain gradient until that
/// file is dropped in.
class _PlayWatchDoors extends StatelessWidget {
  const _PlayWatchDoors();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final accent = context.palette.accent;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: HeroModeCard(
            asset: 'assets/home/roast_hero.png',
            glow: accent,
            aspectRatio: kHeroPillAspect,
            scrim: false,
            onTap: () => _startMatch(context, 'ranked'),
            topRight: IconButton(
              icon: const Icon(Icons.help_outline),
              iconSize: 28,
              color: Colors.white,
              tooltip: 'What is Play?',
              style: IconButton.styleFrom(
                backgroundColor: Colors.black.withValues(alpha: 0.42),
                padding: const EdgeInsets.all(6),
              ),
              onPressed: () => _showPlayInfo(context, accent),
            ),
            // A short caption chip at the very bottom - the core mode must be
            // legible without tapping the "?", and a translucent pill reads
            // cleanly over the crowd without dimming the baked word.
            overlay: _pillCaption('Roast a random stranger — funniest wins'),
          ),
        ),
        const SizedBox(height: 14),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: HeroModeCard(
            asset: 'assets/home/watch_hero.png',
            glow: scheme.secondary,
            aspectRatio: kHeroPillAspect,
            scrim: false,
            onTap: () => MainShell.go(MainShell.tabWatch),
            overlay: _pillCaption('Watch & judge live battles'),
          ),
        ),
      ],
    );
  }

  /// A compact translucent caption pill anchored at the bottom of a hero card,
  /// so a one-line description reads over the art without a full scrim.
  Widget _pillCaption(String text) => Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Flexible(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.55),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.2,
                ),
              ),
            ),
          ),
        ],
      );

  /// Explains Play (roast a stranger / The Basement) - opened by the "?".
  void _showPlayInfo(BuildContext context, Color accent) {
    final body = Theme.of(context).textTheme.bodyMedium;
    Widget heading(String label) => Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Text(label,
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.bold, color: accent)),
        );
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Play'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Get matched with a random opponent for a live, one-on-one roast '
                'battle. No bracket, no waiting - just you, them, and a crowd to '
                'settle it.',
                style: body,
              ),
              const SizedBox(height: 16),
              heading('How it works'),
              Text(
                'You each get a short clock that only ticks while you hold the '
                'floor; roast, then yield. Before the bell you watch their intro '
                'video, so you walk in with ammo. The whole thing is recorded.',
                style: body,
              ),
              const SizedBox(height: 16),
              heading('How you win'),
              Text(
                'The crowd watches and votes - most votes takes it. Wins climb '
                'your rank, and your best moments become a clip you can post.',
                style: body,
              ),
              const SizedBox(height: 16),
              heading('Keep it funny'),
              Text(
                'Go as hard as you want - it is comedy. Deliberate hate or '
                'harassment will not be tolerated.',
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
}

/// The two other ways to play, demoted to a quiet secondary row under the
/// doors: Face-Off (improv) and Challenge a Friend. Compact outlined pills so
/// they stay reachable without competing with PLAY/WATCH.
///
/// Face-Off ships LOCKED (greyed, a padlock): it is a whole second mode that
/// shouldn't compete for a newcomer's attention, so it is held back as an
/// unlock. The exact gate (a subscription, or reaching the top ranks) is still
/// being decided, so tapping just explains it - nothing is wired to the real
/// entitlement/rank yet.
class _MoreWaysToPlay extends StatelessWidget {
  const _MoreWaysToPlay();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          Expanded(
            child: _MiniPlay(
              icon: Icons.flash_on,
              label: 'Face-Off',
              iconColor: const Color(0xFF19B3A6),
              locked: true,
              onTap: () => _showFaceOffLocked(context),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: _MiniPlay(
              icon: Icons.group,
              label: 'Challenge a friend',
              iconColor: scheme.secondary,
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const ChallengeScreen()),
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _showFaceOffLocked(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Face-Off is locked'),
        content: Text(
          'Face-Off is a blind improv mode - you and your opponent riff the '
          'same surprise prompt. It unlocks for subscribers, or once you climb '
          'to the top ranks. Coming soon.',
          style: Theme.of(context).textTheme.bodyMedium,
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
}

/// A compact secondary play pill - icon + label in an outlined surface card.
/// [locked] greys it out and shows a padlock; the tap then explains how to
/// unlock rather than launching.
class _MiniPlay extends StatelessWidget {
  const _MiniPlay({
    required this.icon,
    required this.label,
    required this.iconColor,
    required this.onTap,
    this.locked = false,
  });

  final IconData icon;
  final String label;
  final Color iconColor;
  final VoidCallback onTap;
  final bool locked;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final labelColor = locked ? scheme.onSurfaceVariant : scheme.onSurface;
    return Opacity(
      opacity: locked ? 0.55 : 1,
      child: Material(
        color: scheme.surfaceContainer,
        borderRadius: BorderRadius.circular(14),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: scheme.outlineVariant),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
            child: Row(
              children: [
                Icon(icon, color: locked ? scheme.onSurfaceVariant : iconColor,
                    size: 22),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: text.titleSmall?.copyWith(
                          fontWeight: FontWeight.w800, color: labelColor)),
                ),
                if (locked)
                  Icon(Icons.lock_outline,
                      size: 16, color: scheme.onSurfaceVariant),
              ],
            ),
          ),
        ),
      ),
    );
  }
}


