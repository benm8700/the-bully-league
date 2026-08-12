# Live Roast Battle App — Project Context

This file gives Claude Code full context on this project. Read this before starting any work.

## Branding / App Name — DECIDED
- **App name: "The Bully League."** Chosen over earlier brainstormed candidates (RoastR, Roasted, Torched, Scorched, ClapBack, Cooked, RoastRoulette, Heckle/HeckleHQ). NOT yet checked for trademark/domain/social-handle availability — do that before any public-facing commitment (store listing, marketing, website domain).
- **Flagged tension, not yet resolved**: the app's own moderation policy (see Trust & Safety / Moderation Workflow) treats "intentional disruption/bullying NOT in service of comedy" as a bannable offense — naming the app after the behavior it polices is a deliberate irony the developer is aware of, but worth a final gut-check before it's locked into package IDs and store listings, since renaming after publishing is costly.
- Repo/package identifiers use `bullyleague` as the working slug (e.g. `com.bullyleague.app`) — see Tech Stack / Project Folder Structure.

## Marketing — Comedian Promo Stunts — DECIDED
- Original plan: pay professional comedians to promote the app, including secretly roasting unsuspecting regular users as a promo stunt (they don't know in advance, get surprised by a "master" roaster).
- **DECIDED to keep this tactic, WITH two guardrails**:
  1. **Specific post-match consent from the surprised user** before any footage from that particular stunt is posted publicly — separate from standard recording consent, since being used as a marketing prop is a different situation from an ordinary match. If they decline, the clip stays private/unpublished.
  2. **Public disclosure/labeling when posted** — e.g. "Special Guest Battle" or naming the comedian — rather than presenting it as an ordinary random match. Rationale: presenting a staged encounter as fully organic risks deceptive-advertising concerns (same principle behind FTC sponsored-content disclosure rules) — the AUDIENCE watching the posted clip deserves to know it wasn't a random encounter, separate from the participant's own consent.
- **Action item — NEW**: ask William if he would promote the app on Kill Tony, and offer him some money for the promotion.
- **Paid ambassador/referral push — NEW, DECIDED**: at launch, run a CASH-funded ambassador/referral program (e.g. paying campus or community ambassadors per referral/download+review) — separate from and in addition to the existing in-app points-based referral system. Inspired directly by BeReal's early growth playbook, which paid students per referral and per download-plus-review specifically to seed cold-start growth before organic virality kicked in. Exact payout structure/target communities not yet designed — same "campus/community ambassador" model is a reasonable starting point given target demo (college students) already identified in original marketing notes.

## Support & Launch Strategy — NEW, DECIDED
- **User support channel — DECIDED**: in-app contact/feedback form (not just a plain email) — routes support/help/refund requests through the app itself. Satisfies app store listing requirements for a support contact.
- **Soft launch — DECIDED**: private beta with a small group (friends, via TestFlight for iOS / Play Console internal testing track for Android) BEFORE the full public marketing blitz — catches bugs and lets core mechanics get real playtesting (round length, points balance, matchmaking, etc.) while the stakes and audience are still small. Marketing spend should not go out until the private beta has validated the core loop works. **DECIDED**: ratings/progress from the beta do NOT carry over — everyone resets to fresh 1200 at public launch (beta is purely for testing/bug-catching, not an early-access head start).

## Product Overview
A mobile app (Flutter, Android-first, iOS later) where users are randomly matched 1-on-1 for live 1v1 video roast battles. Winner is determined by community vote (skill-based, not chance). Competitive ranking system with tiers, tournaments, and prizes. Long-term goal: viral growth to 1M+ users, monetized via paid tournament entry fees.

Developer: solo, no prior backend experience, comfortable with cross-platform frameworks, working on Windows, low/no budget for V1. Based in San Diego, CA.

## Core Match Flow
- **Account creation**: phone number + email + password (encrypted). Age-gated via Google Play Age Signals API (see Age Verification below) — no manual ID verification for V1.
- **Onboarding tutorial — DECIDED**: mandatory before a user's first match (covers camera positioning/framing AND ground rules — mic muting, round timing, recording consent). One-time gate only — never replayed for returning users after first completion. **Format — DECIDED**: interactive practice round (not a passive video or slides) — user actually walks through a mock match flow to learn by doing.
- **Pre-match check**: camera preview with face-position guide ("hologram" framing overlay), prompts for good lighting/steady camera/loud enough audio. Both users must pass this before match starts.
  - **Build Order step 3 implementation status**: `PreMatchScreen` built with real camera preview + oval framing guide overlay + a REAL mic-level check (gates the "I'm Ready" button — via Agora's `enableAudioVolumeIndication`, only reports once joined to a channel). Lighting/steadiness/face-visible are advisory-only static prompts, NOT auto-detected — `agora_rtc_engine` 6.6.3's `registerVideoFrameObserver` (needed for real brightness/motion/face frame analysis) is an unimplemented stub in that SDK version (throws `UnimplementedError`, confirmed by reading the package source). Revisit once a package version implements it, or integrate a separate solution (ML Kit for face detection, custom frame analysis) as its own task.
  - Recording Consent (see Legal Items below) is a separate screen shown BEFORE the pre-match camera check, per the "distinct affirmative action" legal requirement.
- **Auto quality flags**: AI/heuristic detection for too-dark, too-quiet, too-shaky, face not visible, mic muted, connection issues. Flagged matches are auto-cancelled and re-queued — NO score penalty either way, just a re-match prompt. This is a technical quality gate only, not content moderation. **Not yet implemented** — the pre-match mic check above is a one-time gate before a match starts, not the same thing as continuous in-match quality monitoring; the dark/shaky/face-visible detection gap noted above applies here too.
- **Quality-flag abuse safeguard — NEW, DECIDED**: since a disqualified match has no rating penalty and simply triggers a rematch, this creates a potential dodge mechanism (deliberately faking bad lighting/audio to escape a match that's going badly). DECIDED: add monitoring/safeguard against this — e.g., track/flag accounts with abnormally high disqualification-triggering rates for review, rather than treating every disqualification as automatically legitimate. Exact detection mechanism/threshold not yet designed — same theme as other abuse-prevention backlog items (vote fraud, multi-account collusion).
- **Match structure — DECIDED**: Random 1v1 pairing, same language only (English only for V1). **Standard format: 3 rounds, 15 seconds max per turn, used for BOTH exhibition and ranked modes** (tournament format may differ — TBD, could be longer for higher stakes).
- **In-turn countdown timer — NEW, DECIDED**: a visible countdown timer during each player's turn (counting down the 15-second max). UI requirement: small, unobtrusive — should not take up significant screen space or distract from the video feed itself.
  - **MUST be a remote/backend-configurable value (e.g., Firebase Remote Config), NOT hardcoded** — developer wants to tune round count/length post-launch without shipping a new app version, to test what format performs best.
  - Each round: one player gets up to the max time to roast (can end turn early, no penalty for time used or joke count). Opponent's mic is muted during that turn.
  - Between turns: "Player X, get ready" screen + 5-second countdown, then roles swap.
  - After all rounds: both mics unmute (volume slightly lowered) while verdict is delivered.
  - Round format should be mode-based (exhibition/ranked/tournament each get one standardized format), NOT user-customizable per match — customization would fragment ranking data and complicate matchmaking.
  - **Build Order step 4 implementation status**: `MatchScreen` built with a real round/turn/countdown state machine, tested live across two devices. Key implementation notes:
    - **No backend match document or Remote Config exist yet** — round count (3), turn length (15s), and countdown (5s) are hardcoded constants in `MatchScreen`, not pulled from Firebase Remote Config as the decision above requires. Needs real wiring once Remote Config is set up.
    - **No real matchmaking either** — both devices join the same hardcoded "test-channel" (same placeholder as step 3), same temp token.
    - **Turn sync is real, not simulated**: one device is elected "host" (lower Agora-assigned uid) and drives the authoritative timer, broadcasting round/turn/phase state to the other over Agora's data-stream messaging (`sendStreamMessage`/`onStreamMessage`) — there's no server-authoritative state (no Firestore match doc yet), so this is a peer-to-peer stopgap. Verified live: both devices showed correctly complementary turn banners ("Your turn coming up" vs. "Opponent's turn coming up") with synced countdown numbers, and both reached the verdict screen simultaneously.
    - **Who goes first each round is always the host** — not a documented product decision, just this implementation's default. Needs a real decision (alternate starting player? coin-flip?) before this is production behavior.
    - **Verdict screen is a placeholder** ("Match complete!" + button back to Home) — community voting (Build Order step 5) isn't built yet.
    - **Known unresolved oddity**: during live testing, the mic mute/unmute log showed 12 state transitions for what should be 13 (12 turn-phase transitions + 1 verdict transition) — the expected mute-state flip going into the final phase didn't show up as a distinct log entry. The visible match behavior (banners, countdowns, both devices reaching verdict together) looked correct, so this weakly suggests a harmless dedup/logging artifact rather than a skipped turn, but this was NOT conclusively root-caused. Worth re-verifying with explicit turnIndex/phase logging before relying on this state machine for real matches.
    - A real bug WAS found and fixed during this work: `AgoraVideoCallService.dispose()` must `leaveChannel()` before `release()`, and the caller (`PreMatchScreen`) must `await` that full dispose BEFORE navigating to the next screen — `State.dispose()` can't be awaited by the Flutter framework, so relying on it to clean up before the next screen's engine joins the same channel is a race that Agora loses with `AgoraRtcException(-17, ERR_JOIN_CHANNEL_REJECTED)`.
- **Pre-match bio reveal — NEW, DECIDED**: after matchmaking pairs two users, show each user the opponent's profile bio (see User Profile System below) for up to 1 minute OR until both players tap "ready," whichever comes first. This gives roasters concrete material ("ammo") instead of relying purely on improv about a stranger's appearance. Full bio is shown pre-match only — NOT persistently visible during the actual roast (keeps video UI clean; also tests what the roaster actually remembers/uses). Optional future iteration: a small persistent one-line tag (name + profession only) pinned in a corner during the match — not required for V1, worth playtesting first. **DECIDED**: rank/rating is NOT shown during bio reveal — only the profile ammo fields (profession, interests, etc). Keeps focus on comedy material rather than skill intimidation/sandbagging psychology.
- **Skip/decline — DECIDED**: users may skip a proposed match after seeing the opponent's bio, before it starts. Limited to 2-3 skips per day (prevents cherry-picking "easy" opponents while still giving an escape hatch for a bad pairing). Needs a daily counter on the user model, reset on a rolling/daily basis.
- **Match-found notification — DECIDED**: both push notification AND in-app indicator when an opponent is found. Important given there's no scheduled "battle window" system — relies on marketing-driven concurrent usage, so users need to be pulled back into the app promptly when a match is ready.
- **Daily "prime time" notification — NEW, DECIDED**: a daily optional push notification (e.g. "Roast Hour starts now!") nudging concurrent usage at a consistent daily time — inspired by BeReal's daily-notification habit loop. NOT a mandatory scheduled window (already rejected earlier) — just a habit-forming nudge that also helps matchmaking liquidity by encouraging more users online at the same time. Exact timing/mechanism not yet designed.
- **Push notification categories — DECIDED**: beyond match-found, also send push notifications for vote reminders (encouraging voting during the 24-hour window — ties into the voting-incentive backlog goal), tournament alerts (start/results), and rank-up/rank-down changes. **Vote reminder frequency — DECIDED**: periodic nudges throughout the 24-hour voting window (not just a single reminder) — exact cadence/count not yet specified. **Notification settings — DECIDED**: per-category toggles in settings (not one global on/off switch) — users can mute vote reminders while keeping match-found alerts on, for example.
- **Mature content consent at signup — DECIDED**: ALL account tiers (Spectator AND Battler) see a general "this app contains mature/offensive content" consent screen at signup. This is separate from and in addition to the Battler-only Recording Consent screen (which applies specifically before an actual match, not at signup).
- **Mid-match disconnect/forfeit — DECIDED**: if a user disconnects before their first roasting turn completes, treat as no-contest (no rating change, both requeued). If a user disconnects AFTER roasting their opponent but BEFORE their opponent gets to roast back, count it as a loss for the person who left (prevents rage-quitting to dodge a response).
- **Tie votes — DECIDED**: a tied vote results in no rating change for either player (counted as neither a win nor a loss) — simplest and hardest to game, avoids needing a coin-flip or sudden-death tiebreaker mechanic.
- **Blocking — DECIDED**: users can permanently block a specific opponent after a match, preventing future pairing with that person. Separate from reporting/banning — this is a personal preference tool, not a moderation action. Needs a `blockedUserIds` array on the user model, checked during matchmaking.
- **Repeat-opponent cooldown — DECIDED**: ideally a 1-day cooldown before the same two people can be re-matched — but if no other opponent is available, they can still be matched again sooner (falls back like the tier-expansion matchmaking logic, availability takes priority over the cooldown when the pool is small). Serves two purposes: keeps matchups varied/interesting, and helps mitigate the collusion/rating-manipulation concern (two accounts repeatedly battling each other on purpose to farm rating).
- **Rate limiting — DECIDED: no limit for V1, revisit later**: developer decided not to impose a daily match cap right now. Flagged as a backlog item to revisit if bot/spam farming actually becomes a problem in practice.
- **Judging**: Community vote ONLY for V1 (no AI judging). Registered + CAPTCHA-verified users get a 24-hour window to vote on winner. Vote count determines winner. **Voting eligibility — DECIDED**: the phone verification already completed at signup is sufficient — no separate re-verification step at the moment of voting. Combined with the CAPTCHA gate, this is treated as sufficient layered anti-fraud defense; extra friction at voting time would hurt participation without a clear fraud-prevention benefit. Revisit only if vote manipulation is actually observed.
  - **Build Order step 5 implementation status**: `castVote` Cloud Function + `VoteScreen`/`VoteEntryScreen` built and verified live end-to-end (real vote written to Firestore, live tally updated). Key implementation notes:
    - **CAPTCHA provider switched from Google reCAPTCHA v2 to Cloudflare Turnstile** after live testing showed reCAPTCHA's image-grid challenges (crosswalks, buses, etc.) are high-friction for real users — worth knowing this was PARTLY an artifact of testing via scripted ADB taps, which read as bot-like and escalated reCAPTCHA to harder challenges more than a real user would typically see, but the friction concern is legitimate regardless. Turnstile's "Managed" mode is usually a single click or fully invisible. Both providers were wired the same way (self-authored WebView + HTML page, not a third-party wrapper package), so the swap only touched ~4 files and one Cloud Function URL — see `lib/widgets/turnstile_challenge.dart`, `assets/turnstile.html`.
    - **No discovery feed exists yet** (see Discovery/feed section) — `VoteEntryScreen` is a manual matchId-paste placeholder for testing, not the real entry point.
    - **Sensitive logic is entirely server-side** in `functions/index.js`'s `castVote`: Turnstile verification (secret key never touches the client), 24h window enforcement, one-vote-per-account (ballot doc ID = voter uid), match-participant exclusion (can't vote on your own match), and account-age vote-weight (< 24h old account = 0.5 weight, matching the Spectator Accounts section's V1 baseline) — confirmed live, a sub-24h-old test account correctly got weight 0.5.
    - **Firestore schema note**: ballots live at `votes/{matchId}/ballots/{voterId}` per the documented schema (not nested under `matches`). Firestore rules block all direct client writes to `votes/**` — only the Cloud Function (Admin SDK) can write ballots.
    - **Three real infrastructure bugs hit and fixed during this work**, worth knowing about if touching Cloud Functions again:
      1. `firebase-functions-test` (dev-only, unused) had a peer-dependency conflict with `firebase-admin` v14+ — removed it rather than pinning `firebase-admin` down.
      2. **A fresh 2nd-gen Cloud Function's "allow public invocation" IAM binding did not apply automatically on deploy** (`firebase deploy` normally handles this) — got a Cloud Run-level 401 ("access token could not be verified") for every call, even correctly-authenticated ones, until manually setting the Cloud Run service to "Allow public access" in the GCP console (Cloud Run → castvote → Security/Permissions). This is the Cloud Run infrastructure layer rejecting the request before it ever reaches Firebase's own `request.auth` check inside the function — the two are different security boundaries. If a future Cloud Function mysteriously 401s despite correct client auth, check this first. This setting is service-level and should survive future deploys.
      3. **`firebase-admin` v14's classic namespaced API (`admin.firestore()`, `admin.auth()`) throws `TypeError: ... is not a function`** when only `require("firebase-admin")` is used — needs the modular API instead (`require("firebase-admin/firestore")` → `getFirestore()`, etc., as used in `functions/index.js` now). Not caught by local testing since there wasn't any — a real gap, worth adding basic Cloud Function smoke tests before this grows further.
    - **Match participants' Firestore UIDs are exchanged peer-to-peer** via the same Agora data-channel messaging as the match state sync (see Build Order step 4 notes) — there's still no real backend-authoritative match creation, so `MatchScreen` (whichever side is host) writes the `matches/{matchId}` doc directly from the client at verdict time.
- **Username impersonation (celebrities/public figures)**: not a V1 concern per developer — no dedicated reserved-name/impersonation check planned for now.
- **Modes**: Exhibition (casual, doesn't affect ranking), Ranked (affects rating — DECIDED: unlocked only after completing a few exhibition matches first, exact number TBD, lets new users get comfortable before results count. **DECIDED**: progress toward unlocking Ranked is shown to the user, e.g. "3 matches until Ranked unlocks" — not a silent unlock), Tournament (bracketed, prizes).
- **Discovery/feed — DECIDED**: completed ranked (and tournament) matches are visible/browsable to ALL users in an in-app discovery feed, not just the two players and voters. Ties in with the existing "top-5 roasters" website homepage concept — worth an in-app equivalent feed for engagement. **Sort order — DECIDED**: two-tab approach — default "Recent" tab (most recent first, guarantees every match gets visibility during its 24-hour vote window) plus a secondary "Trending" tab (sorted by vote count) for browsing top content. Avoids the cold-start trap of a trending-only feed (zero-vote matches never surface, so never get voted on). **DECIDED**: paid/promotional comedian matches (see Marketing — Comedian Promo Stunts) get their own separate "Featured" spotlight, distinct from Top 5 and Trending — makes sense given they're a distinct, curated content type rather than organic community content.
- **Username content filter — DECIDED**: usernames are filtered for slurs/offensive content at creation (basic profanity/slur word-list check, or reuse the moderation API already planned elsewhere). Distinct from the in-battle free-speech policy — usernames are permanent, unavoidable, and publicly displayed (leaderboard, website, hall of fame) to people who never opted into the battle format, and persistent public identifiers are something app stores actively review even for otherwise permissive apps.
- **Username changes — DECIDED**: allowed, but with a cooldown (e.g. once every 30-60 days, exact interval TBD) to prevent using frequent changes to dodge recognition after bad behavior or cycle around moderation. Same content filter applies on every change, not just at initial signup.
- **Solo practice mode — NEW, DECIDED**: add a solo practice mode — record yourself with no opponent, just to warm up/rehearse before a real match.
- **Device support — DECIDED**: phone + tablet support (not phone-only).
- **Video/streaming**: NO live external streaming for V1 (no YouTube live). **Recording scope — DECIDED**: only ranked and tournament matches are recorded and eligible for the website/Instagram highlight pipeline. Exhibition matches are NOT recorded/posted (casual, no ranking impact, no content-pipeline use).

## Ranking System
- **Rating — DECIDED**: Chess-style Elo-like numerical rating system, used as the underlying math (not shown directly to users — see Laugh Meter below). Everyone starts at a flat **1200**. No hard ceiling (unbounded). Soft floor at ~100 (prevents demoralizing bottomless losing spirals).
- **K-factor — DECIDED (variable, not flat)**: use a VARIABLE K-factor rather than one flat rate for all players — modeled on how real chess federations (USCF/FIDE) handle this. Lower/newer-tier players (roughly ranks 1-4) get a HIGH K-factor — bigger rating swings per match, faster early climbing, quick gratification, forgiving of an early loss or two. Higher-tier players (roughly Headliner and up, especially near the GOAT top-5 cutoff) get a LOW K-factor — smaller swings, rating only moves with sustained real performance, every win at the top genuinely has to be earned. Chosen over a hard "different system above X rank" split specifically because a single continuously-scaling K-factor achieves the same early-gratification-then-real-competition FEEL without a jarring rule-change moment a player could hit and feel blindsided by. Exact K-factor values per tier band not yet set — needs real tuning once analytics data exists (see Firebase Analytics decision).
- **Points/currency — DECIDED, separate system from rating**: a second currency that only ever increases (earned via participation, more for wins) — deliberately structured to never go down, unlike rating, so players on a losing streak still have something accumulating (retention/engagement reasoning). Spent on cosmetic-only unlocks (profile borders/frames, badge flair, alternate UI themes) — nothing that affects gameplay/matchmaking.
  - **Real-money purchase — DECIDED: earn-only for V1, revisit for V2**: recommendation was to eventually allow buying points via Apple/Google IAP (low legal risk since it's cosmetic-only, no prize/chance element unlike tournament entry fees) but NOT build this for V1 — validate that the cosmetic-unlock system actually drives engagement with earn-only points first, before investing in payment infrastructure for something unproven.
- **GOAT-tier exclusive perks — NEW, DECIDED (concept only)**: the top rank should unlock something beyond just the badge/title (special cosmetics, priority matchmaking, and/or access to exclusive GOAT-only tournaments) — ties back to original vision of "prestigious status, cool unlocks." Developer has not yet decided WHICH specific perks — still needs its own design pass/brainstorm.
- **Tier system — REVAMPED, DECIDED (single ladder, not nested leagues)**: originally considered separate "leagues" (Novice/Intermediate/Professional) each containing sub-ranks — simplified to ONE ordered ladder of 10 titles instead, since two coordinate systems (league + rank) is more confusing for users than one clear ladder. Each title implies its own tier — no separate league label needed.
  - **The 10 ranks (lowest to highest) — DECIDED**:
    1. Average Joe
    2. Open Micer
    3. Class Clown
    4. The Funny Friend
    5. Door Guy
    6. Regular
    7. Headliner
    8. Legend
    9. Hall of Famer
    10. GOAT
  - **Bottom tier — DECIDED**: no 11th tier added below Average Joe. Average Joe remains the floor of the ladder.
  - **Promotion mechanic — DECIDED**: each tier requires BOTH a rating threshold AND a minimum number of ranked matches played to unlock (prevents a lucky early win streak from vaulting a low-sample-size account into a high tier — same logic as "placement matches" in games like League of Legends). Exact thresholds/match minimums not yet set — needs starting placement (1200) to land somewhere in the middle of the ladder, not at the bottom, so new players can move in either direction.
  - **GOAT tier — IMPORTANT EXCEPTION, DECIDED**: unlike ranks 1-9 (fixed rating thresholds), GOAT (rank 10) is capped at strictly the TOP 5 rated players platform-wide at any given time — a live leaderboard position, not a threshold. This is the ONE deliberate exception to the "fixed thresholds, not live percentiles" design principle used for every other rank — chosen specifically because exclusivity/scarcity fits GOAT's role as the single most prestigious tier (being bumped out by someone else's rise is part of what makes it meaningful, same as "#1 in the world" in real competitive systems). Practical implication: a GOAT-tier player can be demoted purely because a 6th player's rating surpassed theirs, even with no loss of their own — this should be reflected honestly in the rank-down popup messaging for this specific case if possible (a demotion here isn't necessarily "you got worse," it's "someone else got better"). Resolves the earlier "separate #1/Champion badge" question — the whole GOAT tier now IS that exclusive recognition, no separate badge needed.
  - **Hidden criteria — DECIDED**: exact rating/match thresholds for each tier are NOT shown to users (keeps it mysterious/motivating, same pattern as Overwatch/League rank systems). Still show a partial progress indicator (e.g., the laugh meter visually filling toward next tier) even without exposing precise numbers. Note: GOAT's top-5 cutoff is inherently visible/comparative by nature (it's a leaderboard position), so "hidden criteria" mainly applies to ranks 1-9.
  - **Matchmaking — DECIDED**: pair users within the same tier first; if no match found, expand to ±1 tier. **Fallback — DECIDED**: if still no match, gradually widen the tier search range further over time (e.g., every 30 seconds expand the range) rather than waiting indefinitely or falling back to a truly unrestricted match — keeps matches reasonably skill-appropriate even during low-liquidity periods (early days, off-peak times) while still guaranteeing a match eventually.
  - **Season reset — DECIDED**: soft reset, not hard reset — pull all ratings partway back toward the center (e.g., 50% of the distance back to 1200) at the start of each season/trial period, rather than resetting everyone to 1200 flat. Preserves skill differential while compressing early-farming advantage. Combined with the per-tier minimum-matches requirement, this naturally re-gates everyone through a mini placement period each season. **DECIDED**: each season should also come with exclusive seasonal cosmetics (limited-time items tied to that season, not permanently available) — proven retention pattern (Fortnite/League/Overwatch-style), pairs naturally with the reset as both a competitive fresh-start AND a content reason to return. Build as an evolution of the base cosmetic store, not a separate system.
- **Display — DECIDED: "Laugh Meter" concept**: underlying Elo number is invisible plumbing; user-facing display is a themed visual gauge/meter (e.g., a heat gauge from "cold" to "on fire" to a top-tier glow) that fills and shifts as rating changes, with the current rank title as the primary label. Raw number can still be exposed in a detailed stats view for players who want precision.
- **Rank-up/rank-down popup — NEW, DECIDED**: when a user's tier changes (up OR down), show a celebratory/roast-style popup on next login — cool visual treatment + a funny, on-brand line specific to that rank transition (not generic). Direction-specific tone: rank-UP messages should feel earned/cocky-but-fun, rank-DOWN messages should be a playful roast rather than purely discouraging. This is a real content-writing task (10 ranks × 2 directions, ideally with multiple variants per transition to avoid repetition) — NOT yet fully written, treat as its own to-do. Seed examples generated during planning, for tone reference only:
    - Average Joe → Open Micer (up): "You bombed less than usual. Welcome to Open Mic Night."
    - Regular → Headliner (up): "Congrats, you're the main event now."
    - Hall of Famer → GOAT (up): "Don't let this get to your head, but you're funnier than everyone else."
    - Open Micer → Average Joe (down): "Wow, you're awful. Maybe it's time to find a new hobby."
    - GOAT → Hall of Famer (down): "Even legends have off nights. Get back in there."
- Profile shows ranked win/loss record (e.g. "5 wins, 3 losses") plus current rank title. Needs `wins` and `losses` counters on the user model (incremented on ranked match completion), separate from exhibition matches which don't affect this.
- **Build Order step 6 implementation status**: Elo + tier logic (`functions/rating.js`), `finalizeMatch`/`syncGoatTier` (`functions/matchFinalization.js`), a scheduled `finalizeExpiredMatches` (hourly, real 24h window) + a dev-only `debugFinalizeMatch` callable (force-finalizes immediately, bypasses the window), Firestore rules locking `rating`/`rankTitle`/`rankedMatchesPlayed`/`wins`/`losses` to Cloud-Function-only writes, and a `_RankBadge` display on `HomeScreen` are all built, deployed, and verified end-to-end on a real ranked match: PlayerOne (loser) 1200→1186, PlayerTwo (winner) 1200→1214, matching the K=28 formula for equal-rated players exactly; wins/losses/rankedMatchesPlayed all incremented correctly. All rank/match thresholds in `functions/rating.js` (`RANK_TIERS`, `GOAT_POOL_SIZE`, K-factor breakpoints) are still explicit placeholders needing real tuning, per the Open/Not-Yet-Decided list below.
  - **Real bug found and fixed**: `AgoraVideoCallService.joinChannel()`'s Dart `Future` resolved as soon as the join *request* was accepted, not once `onJoinChannelSuccess` actually fired — but `createDataStream()` (needed before `sendMatchMessage` can work) was only called inside that later event. Callers that used the channel immediately after `joinChannel()` returned (MatchScreen's host/guest identity exchange) could call `sendMatchMessage` before `_dataStreamId` was set, which silently no-ops — this caused real, intermittently-reproducing match-save failures ("missing player identity"). Fixed with a `Completer` that `joinChannel()` now awaits, only completing after both `onJoinChannelSuccess` and `createDataStream` finish. Verified fixed via a real two-device match saving successfully.
  - **Real gap found and fixed**: the app had no `LoginScreen` at all — only `SignupScreen`, wired as `AuthGate`'s "signed out" state. There was no way to sign back into an existing account after signing out. Added `lib/screens/auth/login_screen.dart` plus a toggle link on both screens.
  - **Real bug found and fixed, twice**: the Signup↔Login toggle links initially used `Navigator.pushReplacement`, which **replaces the root route that hosts `AuthGate`'s auth-state `StreamBuilder`** — so after that navigation, there was no `AuthGate` left anywhere in the tree to react to sign-in/sign-up succeeding, and the app would get stuck showing the login/signup screen forever no matter what Firebase Auth did (confirmed live: `signInWithEmailAndPassword` succeeded and persisted a session, but the UI never advanced — only a full app relaunch, which rebuilds `AuthGate` fresh from `main()`, picked the session back up). Fixed two ways together: (1) changed `pushReplacement` to `push` so `AuthGate` stays mounted underneath as a real root route, and (2) added `Navigator.of(context).popUntil((route) => route.isFirst)` after a successful sign-in/sign-up so the pushed Login/Signup route gets popped and `AuthGate`'s already-updated `HomeScreen` becomes visible. Both parts are necessary — either alone still leaves the app stuck.

## User Profile System — NEW, DECIDED
Goal: give roasters concrete material about a stranger instead of relying purely on appearance-based improv. Appearance-roasting is still allowed (free speech stance applies), just not actively encouraged via required fields. Filled out at signup, editable later.
- **Required fields** (kept short to minimize signup drop-off): profession, education, hometown/location, interests.
- **Optional fields** (more sensitive — user chooses whether to disclose): relationship status, pets, favorite food. (Weight explicitly EXCLUDED per developer decision — common vector for harm beyond comedy, combined with no real-time speech moderation.)
- **Free-text ammo field** (optional): one open field where users can share something embarrassing or anything else they want opponents to have material on. Framed to encourage voluntary, consensual ammo rather than relying purely on things they didn't choose to share.
- **Photos — DECIDED**: minimum 5 photos required at signup. Photos must pass through the SAME automated visual content moderation used for live matches (nudity/inappropriate content detection — see Content Policy & Moderation) before being accepted, not just the live video stream. **DECIDED**: at least ONE of the 5 must be a clear, unobstructed face photo (specifically required, not just any 5) — helps both the profile/bio-reveal experience and catfishing/impersonation prevention.
- **Honesty**: cannot be enforced (self-reported/unverifiable). Frame in UI as "funnier if it's true" (self-interest framing) rather than a compliance request.
- **Manual profile approval — DECIDED FOR V1, FLAGGED AS NOT SCALABLE**: developer will manually review and approve each profile before the user can access the platform, intended to catch obvious lies/dishonesty. IMPORTANT CAVEAT surfaced during planning: manual review realistically can only catch spam accounts, fake/stolen photos, and obviously fake/offensive profiles — it CANNOT verify claims like actual profession or education without a much bigger identity-verification system. Also flagged: this does not scale past what one person can personally review, which is in direct tension with the stated goal of rapid viral growth via marketing blitz. Treat this as a temporary V1-only measure to revisit (options: automated photo/liveness checks, or switch to approve-by-default + post-hoc reporting) once signup volume exceeds what's manually reviewable.
  - **Re-review on edit — DECIDED**: editing profile text fields alone does NOT trigger re-review (one-time gate for those). Uploading NEW photos DOES trigger another manual review pass — consistent with manual review's real value being photo/spam/impersonation screening rather than fact-checking text claims.
- **Referral/invite system — NEW, DECIDED**: bonus points (cosmetic-unlock currency) awarded for successful referrals, built into the points economy. IMPORTANT anti-abuse design: reward triggers only when the referred friend completes profile approval AND plays their first match — NOT just on signup — to prevent farming referral rewards with throwaway/fake accounts.
- **Pre-match reveal mechanic**: see Match Structure above — bios shown for up to 1 min or until both ready, not persistently visible during the roast itself.
- **Build Order step 7 implementation status**: `ProfileScreen` (`lib/screens/profile/profile_screen.dart`) built and verified live — loads/edits the four required text fields plus the three optional fields plus ammo text, writing to `users/{uid}.profile` via a plain `.update()`. Photos (5 required, face-photo requirement, visual-moderation gate) and manual approval are explicitly DEFERRED to step 9a per a scope-check decision — everyone stays a full Battler for now, no Spectator/Battler split yet, no `approvalStatus`/`photoUrls` fields written. A `LeaderboardScreen` (`lib/screens/leaderboard/leaderboard_screen.dart`) was also built — single-field `orderBy('rating', descending: true)` query (no composite index needed), verified live showing PlayerTwo/SeventhVoter/PlayerOne in correct rating order.
  - **Real bug found and fixed**: the `users/{userId}` Firestore rule's `allow update` compared fields via direct access (`resource.data.rating == ...`) rather than `.get(field, default)`. On a document where that field is entirely absent, direct access throws a rules-evaluation error rather than just failing the comparison — and that error denies the WHOLE write, including completely unrelated fields like `profile`. This is real, not just theoretical: a legacy test account (`SeventhVoter`, created before the step 6 signup change started writing `rating`/`rankTitle`/etc. at account creation) had no Firestore doc at all, so every profile save failed with `permission-denied` no matter what the write actually contained. Fixed by switching all five protected-field comparisons in `firestore.rules` to `.get(field, null)` so a missing field degrades to a normal (still-protected) comparison instead of a hard rule error. Backfilled the one affected legacy test account by hand; going forward every account gets these fields atomically at signup, so this should only ever matter for further schema migrations, not new signups.
  - **Real bug found (client-side, not a rules issue)**: after fixing the rule and confirming an identical write succeeds via a raw authenticated REST call, the Flutter app's `.update()` call kept failing with the exact same `permission-denied` for two more retries in the SAME running app process — Firestore's `WriteStream` appears to cache a rejected-write state that doesn't clear just because the underlying document changed externally. Only a full app restart (which resets the Firestore SDK's local state) picked up the fix. Worth knowing if a similar "the rule is right but the client keeps failing anyway" symptom shows up again — try a fresh app process before assuming the rule/data fix didn't work.
  - Model classes (`lib/models/user_model.dart` etc., per the Project Folder Structure section) still don't exist — screens read/write Firestore documents as raw `Map<String, dynamic>` throughout, including this step's new screens. Not blocking so far, but worth a pass once enough screens touch the same shapes that drift becomes a real risk.

## Content Policy & Moderation
- **Free speech stance (explicit developer decision)**: offensive language, slurs, and no-holds-barred content are ALLOWED by design — this is a comedy platform, not a censored one. Users consent to this on signup.
- **NO real-time automated content moderation** (no auto-mute/auto-end on detected slurs) — explicitly rejected by developer to preserve free speech. This applies to CONTENT only.
- **Moderation model**: reactive only — human moderators review user-submitted reports after the fact. Bannable offense = intentional disruption/bullying NOT in service of comedy (admin discretion).
- **Technical quality flags (lighting/audio/camera) are separate from content moderation** — those are automated and do not touch what users say.
- **Visual content moderation (nudity/inappropriate physical actions) — DECIDED, separate from speech policy**: automated real-time detection for nudity/explicit physical acts during video, using an off-the-shelf visual moderation API (e.g., AWS Rekognition, Google Cloud Vision SafeSearch, Azure Content Moderator, or specialized providers like Hive/Sightengine). On detection: auto-blur video feed and/or auto-end the match. This is VISUAL/ACTION moderation only — it does not touch audio, speech, or language, and does not conflict with the free-speech content policy above. Treat as its own module (e.g., `visual_moderation_service.dart`) wrapped behind an interface like the other external dependencies, so the provider can be swapped later.

## Age Verification — DECIDED: Option 2
- Using **Google Play Age Signals API** (beta) to get age bracket (0-12/13-15/16-17/18+) at account creation, gating access until 18+ signal confirmed.
- **Under-18 handling — DECIDED**: hard block. If the age signal returns anything under 18, account creation is blocked entirely — no account, no limited/junior mode.
- Will add **Apple's Declared Age Range API** when iOS version is built.
- Rationale: free/low-cost, leans on store-level infrastructure already being built for 2026 state law compliance (Texas, Utah, Louisiana app-store age verification laws), doesn't conflict with the free-speech content policy since it governs WHO can access the app, not what they can say.
- Do NOT store actual birthdate — only store a boolean `ageVerified` flag / bracket signal, per data minimization best practice.

## Prize & Tournament Legal Structure
- **Classification**: Paid-entry + skill-judged winner (community vote on comedic performance) = legally a **skill contest**, not a sweepstakes/lottery. This allows charging entry fees (unlike a sweepstakes, which cannot require payment).
- **V1**: NO real cash prizes — points/in-app rewards only. Framework must be built to support cash prizes being flipped on later without restructuring.
- **Entry fees**: YES, paid tournaments will require an entry fee (developer decision).
- **Geofencing plan for future cash prizes**: launch cash-eligible states = most of the US, EXCLUDING the commonly-restricted skill-gaming states: Arizona, Arkansas, Connecticut, Delaware, Louisiana, Montana, South Carolina, South Dakota, Tennessee (and treat Indiana, Iowa, Maine, Florida as "needs individual legal review" rather than auto-included). This list is NOT static — must be stored as configurable data, not hardcoded logic, since state law changes over time.
- **Compliance notes for later**: Florida/New York have registration/bonding thresholds once prize pools cross certain dollar amounts. Winners of prizes over $2,000 require a 1099 tax form. A sweepstakes/contest attorney should review before real money is activated — this is not a DIY legal area.
- **International**: default to points-only outside the US until each country's contest/gambling law is separately reviewed (UK, Canada, Australia each have their own regimes).

## Legal Items Beyond Prize Structure (identified in later planning pass)

### Recording Consent — IMPORTANT, needs a dedicated UI step
- California (and CT, DE, FL, IL, MD, MA, MI, MT, NV, NH, OR, PA, VT, WA) require ALL-PARTY consent before recording a conversation, and this explicitly covers video calls, not just phone calls. Penalties in CA reach $2,500 criminal fine + $5,000 civil damages per violation.
- Current plan (camera/lighting pre-match agreement) does NOT satisfy this — need a distinct, explicit, unmissable consent step before each match confirming (a) the match will be recorded and (b) it may be posted publicly. This should be a separate affirmative action, not just buried in Terms of Service.
- **Implemented (Build Order step 3)**: `RecordingConsentScreen`, shown before the camera/lighting pre-match check, as its own distinct affirmative-action step (checkbox + explicit "I Agree", not buried in ToS). **Copy is a functional placeholder, NOT yet lawyer-reviewed** — needs real legal review before launch, same as the rest of the ToS/Privacy Policy per the item below.

### Random-Stranger-Video-Pairing Design Risk — read before loosening age verification
- Omegle (the best-known random-stranger video chat platform) shut down in 2023 after years of lawsuits alleging the CORE DESIGN — randomly pairing strangers including minors with adults, with minimal age verification — was itself legally defective, independent of what was said/done on any call.
- A court rejected Omegle's Section 230 defense in one case specifically because the claim targeted the product's design (matching mechanism), not the content exchanged. This directly parallels the 2026 CA/MA "negligent design" rulings noted elsewhere in this doc.
- Implication: this app's core mechanic (random stranger video pairing) is the same fundamental risk pattern, even though content differs (comedy vs. the abuse Omegle enabled). The Google Play Age Signals decision is doing real legal/safety work, not just a compliance checkbox — treat any future decision to weaken or bypass it as a serious risk, not a minor product tweak.

### Terms of Service + Privacy Policy — required before app store submission
- Google Play and Apple both require a working privacy policy link before approving an app listing. Must be drafted before submission.
- Must include: recording/all-party-consent disclosure, data collection practices (phone/email storage), age-gating disclosure.

### Content/Footage Usage Rights — needed for the marketing plan
- ToS must explicitly grant the platform rights to use, clip, and redistribute recorded match footage (Instagram highlights, website features, etc.) — this is legally separate from the right to record it in the first place. Both need explicit user consent.

### Payment Processor Restrictions (later-stage, when cash prizes activate)
- Mainstream processors (Stripe, PayPal, etc.) often independently flag/restrict "skill contest"/prize-money platforms as higher-risk merchant categories, separate from state law legality. Budget time to find a processor that explicitly supports this category when activating entry fees — don't assume the first choice will onboard the business.

### Business Entity Formation — DECIDED: deferred, not a V1 blocker
- **DECIDED**: entity formation is explicitly DEFERRED until the app is actually about to process real money (i.e., real tournament entry-fee payments go live) — NOT needed for V1 build/launch itself. Rationale: V1 does not process real payments at all (the `entryFee`/`prizeType` schema fields exist for future readiness, per the "build the framework now, activate later" pattern — see Prize & Tournament Legal Structure), and the app's product-design risk factors (age verification, content moderation, recording consent, etc.) are mitigated by the product decisions themselves, not by which legal entity sits behind the app. No reason to take on new LLC formation/maintenance overhead before there's any real traction to justify it.
- Developer has an existing LLC (unrelated to this app, tied to real estate) and, for now, is not forming a new one or restructuring around this project.
- **Revisit trigger — DECIDED**: the actual decision point to revisit entity structure (new dedicated LLC vs. using the existing one vs. other options) is the moment real entry-fee payment processing is about to go live — not before. At that point, worth a real conversation with whoever handles business/legal matters — using the existing unrelated LLC at that stage would mean the two ventures share liability exposure (a lawsuit against one could reach the other's assets), which is the tradeoff to weigh then, not now.
- **Business/company name**: not yet decided — not currently blocking, since no entity/App-Store-submission work is happening yet either.

## Trust & Safety / Moderation Workflow — DECIDED
- **Report-to-ban decisions**: case-by-case, no fixed graduated-consequence tiers (no automatic warning → temp ban → permanent ban ladder). Admin/moderator discretion per report, consistent with the original "banned for any reason at any time if admin so chooses" stance.
- **Report categories — DECIDED**: reporter picks from categorized reasons (e.g. harassment, hate speech, technical/quality issue, inappropriate content, impersonation) rather than one generic report button — helps route/prioritize reports for review.
- **Ban appeal — DECIDED**: a simple appeal/dispute button/flow should exist for banned users, even though the underlying ban decision remains admin-discretion. Gives banned users recourse to contest a decision without guaranteeing reversal.

## Compliance / Account Management — NEW NOTE
- **CCPA data deletion**: since developer is California-based with California users, need a user-facing "delete my account / delete my data" flow in account settings from V1 — required under CCPA, cheaper to build in from the start than retrofit once support requests start coming in.

## Cost Planning — IMPORTANT FLAG, not yet resolved
- **Agora video minutes vs. marketing plan tension**: Agora's free tier (~10,000 min/month) sounds generous but a single 3-round match (including bio reveal, countdowns, verdict) runs roughly 2-3 minutes of video. A moderate-sized viral spike (e.g. 5,000 matches in a single day, small for a real marketing blitz) would exceed the ENTIRE monthly free tier in a single day. This is a direct tension with the stated "low/no budget" + "heavy marketing blitz for rapid growth" combination. Action item: calculate realistic cost-per-match on Agora's paid tier BEFORE marketing spend goes out, so there's a known budget number rather than a surprise bill once growth actually happens.

## Video Retention Policy — DECIDED
- Only "posted" highlight clips (the auto-edited, publicly shared versions — see Auto-Editing for Highlights) are retained. Raw/unposted match recordings are deleted after **7 days** — long enough to cover the 24-hour vote window plus reasonable report/moderation review time, short enough to control storage cost. This also bounds how long the recording-consent applies (see Recording Consent legal item).

### Website — Account & Tournament Rules — DECIDED
- **Hall of Fame — DECIDED: DROPPED**, not building this as a separate feature. Rationale: the GOAT tier (top-5 leaderboard position) already serves the "fame/prestige" purpose the Hall of Fame concept was meant to provide — a separate feature would be redundant/confusing alongside it.
- **Website homepage — DECIDED**: feature the current Top 5 ranked roasters on the homepage (this was already part of the original plan). CONFIRMED: this must auto-update dynamically — as soon as someone's ranking changes such that they enter/exit the top 5, the homepage feature swaps automatically. No manual curation needed; this is a live query against current ratings, not a static/admin-curated list.
- **Shared login**: website uses the SAME account/login as the app (single Firebase Auth identity across both), not a separate signup.
- **Tournament minimum-entrants threshold ("golden parachute")**: if a tournament doesn't hit its minimum entrant count, it is cancelled and all entry fees already paid are refunded.
- **Async bracket no-show/forfeit — RECOMMENDED DEFAULT (confirm or override)**: if a player misses their match window, it counts as an auto-loss/forfeit and the opponent advances by default — consistent with the mid-match disconnect rule (a no-show shouldn't get a free refund, or entering-and-never-playing becomes a risk-free way to get a fee back). If BOTH players in a bracket match miss the window, both are eliminated with no refund. Flagged as a recommendation applying existing logic, not yet explicitly confirmed by developer.
- **Multiple concurrent tournament entries — DECIDED**: allowed, no restriction. Since brackets are async/rolling (not scheduled live events), there's no real scheduling conflict forcing a one-at-a-time rule — a user can play multiple async tournament matches on their own time. Restricting would just cost entry-fee revenue with no real benefit.
- **Bracket seeding — DECIDED**: random seeding (chosen as most fair over rating-based seeding). Note: since seeding is random, mismatched-rating pairings will happen often in tournaments — the existing standard Elo bonus (beating a higher-rated opponent gains more rating than beating an equally-rated one, see Rating System) ALREADY covers the developer's request that "beating a much higher rank person should give a rating bonus" — no new mechanic needed, just confirming it applies to tournament matches too, not only regular ranked ones.
- **Bracket size — DECIDED**: flexible, any number of entrants (not restricted to fixed power-of-2 sizes like 8/16/32/64). TECHNICAL NOTE: this means bracket logic must handle BYES (some players automatically advancing a round without playing) when the entrant count doesn't divide evenly — a real implementation detail to account for, not just a UI/rules matter.
- **Tournament withdrawal — DECIDED**: a user CAN withdraw from a tournament and get refunded, as long as it's before the bracket actually starts. Separate from the "tournament cancelled due to insufficient entrants" refund rule already decided — this is a voluntary individual withdrawal, not a tournament-wide cancellation.

## Problems To Solve Later (Backlog — flagged during planning, not yet designed)
- **Cosmetic store / reward economy design**: what points can be spent on (draft categories discussed: profile borders/frames, badge flair, alternate UI themes, match entrance effects, username styling) and what earns points (participation, wins, voting, streaks, referrals, rank-ups) — deferred, needs real playtesting to balance actual values. Basic structural approach discussed: a `cosmeticItems` collection + `ownedItemIds`/`equippedItems` on the user model, no payment processor needed since V1 stays earn-only.
- **Weekly recap notification — NEW, DECIDED**: send a weekly summary push/email (match count, rank progress, top-voted clip, etc.) to re-engage users. Content/design not yet detailed.
- **Voting incentive mechanism — REVISITED, DECIDED (structure set)**: want to incentivize ranked members and spectators to vote on matches they weren't part of, so vote counts aren't just the two competitors' friends. Structure decided:
  - Points reward per vote cast (using existing points currency) — naturally self-limiting since it's one vote per account per match, so no farming risk from voting itself.
  - Daily voting streak bonus for consecutive days with at least one vote cast.
  - **NEW IDEA — a separate "Judge" progression track for voters**: mirroring the Battler rank/title ladder, give active voters/spectators their own light prestige track (e.g. rising through judge-specific titles) separate from Battler ranks. Gives Spectators their own reason to stay engaged and return daily, not just points — same psychological hook (status/prestige climbing) that works for Battlers, applied to the voting audience. Titles/thresholds not yet designed.
  - Exact point values and streak bonus amounts still need real playtesting to balance — structure decided, numbers not yet set.
  - **Daily/weekly quest system — NEW, DECIDED**: add a lightweight quest system layered on top of streaks (e.g. "vote on 3 matches today," "win 1 match this week") tied to the existing points currency as rewards. Rationale: research on 2026 app retention shows apps combining streaks + quests + progression ("meaningful play," not just raw points) see meaningfully higher Day-30 retention than points-only systems — gives users explicit direction on what to do each session rather than just a vague reason to open the app. Quest content/rotation/exact rewards not yet designed.
- **Vote integrity — advanced layer (V2+)**: device/IP fingerprinting to catch multiple accounts voting from the same device (needs to be signal-weighted, not a hard block, since legitimate device/network sharing happens), reputation-weighted voting (established accounts' votes count more than brand-new ones), and anomaly detection for suspicious vote spikes routed to manual review. These are beyond V1 scope/infrastructure.

## Spectator Accounts — NEW, DECIDED
- **Two-tier account system**: split account creation into a lightweight **Spectator** tier and the full **Battler** tier.
  - **Spectator account**: lightweight signup (phone/email verification only). Can browse the in-app discovery feed, watch matches, and vote. Skips photos, bio/profile fields, tutorial, and manual approval entirely — those are only required for the Battler tier.
  - **Battler profile**: the full existing flow (5 photos, bio fields, tutorial, manual approval) — only required once/if a Spectator decides they want to queue for an actual match. A user can upgrade from Spectator to Battler at any time.
  - Rationale: forcing every download through the full battler onboarding (photos + manual approval + tutorial) creates unnecessary friction for someone who just wants to watch/vote after seeing a shared clip — costly for a growth-focused launch. Spectators also become a natural, low-friction pool of voters for the voting-incentive idea above.
- **Voting integrity for Spectators — DECIDED (V1 baseline)**: since spectator accounts skip manual approval, voting-fraud defenses lean more on automated signals:
  1. Phone verification required (already standard for all accounts) — block VOIP/virtual numbers specifically at signup (most phone verification providers, including Firebase's, can detect and reject these) to prevent cheap mass burner-account creation.
  2. CAPTCHA at the moment of voting (already decided elsewhere).
  3. One vote per account per match (already implicit in data model).
  4. **NEW**: account-age gating on vote weight — an account must exist for a minimum period (e.g. 24-48 hours, exact number TBD) before its vote counts at full weight, specifically to defeat "spin up many accounts right before a vote closes" attacks.
  - Advanced defenses (fingerprinting, reputation weighting, anomaly detection) are backlog items — see Problems To Solve Later above.

## Website & Data Deletion — NEW, DECIDED
- **Website age gating**: NOT full login/age-API verification just to watch (would kill the viral sharing loop — someone clicking a shared clip shouldn't hit a login wall). Instead, a lightweight self-attestation click-through content warning ("mature content, confirm 18+") for anonymous viewing, no login required. Full verification stays required for account creation and voting (already decided) — passive viewing carries a different (lower) risk profile than the app's active stranger-pairing mechanic, which is what drove the stronger verification requirement there.
- **CCPA deletion vs. already-posted highlights**: on account deletion, KEEP highlight clips already publicly posted before the request (consented under ToS at time of posting, already publicly distributed — deleting an account doesn't unpublish an already-live Instagram post). DO delete/scrub profile data, unposted raw footage, and stop future use of their identity. Flagged as a working answer, not guaranteed-compliant — worth a real legal check on CCPA mechanics for already-published content specifically.
- **Referral reward tiers — DECIDED**: smaller reward for a referred friend becoming an ACTIVE Spectator (e.g., casts first vote — same anti-abuse "activation not just signup" logic as before), full/larger reward reserved for Battler activation (profile approval + first match, as originally decided). Reinforces the voting-incentive backlog goal too.

## App Store Compliance — IMPORTANT, TIME-SENSITIVE
- **Comments feature — NEW, DECIDED**: planning a comments/replies feature on posted highlight clips (website and/or Instagram). CORRECTION from earlier planning: Apple's Guideline 1.2 24-hour SLA applies only to content INSIDE the reviewed app itself — it does NOT reach the separate website or Instagram. If comments only live on the website/Instagram (not inside the app), Apple's rule does not apply to them. What DOES still apply, for different reasons: (1) Instagram comments are governed by Meta's own community guidelines — Meta can restrict/suspend the account independent of Apple, a real risk to the marketing channel but not an App Store issue; (2) website comments carry general platform liability/Section 230 considerations (see Legal Items section) but not Apple's specific SLA. Apple's 24-hour rule would only become directly relevant here if a comment section is ever added INSIDE the app itself (e.g. commenting on a clip within the in-app discovery feed) — not decided/planned currently. Recommended moderation approach regardless of platform: automated text moderation (e.g. Google Perspective API, OpenAI moderation endpoint, or similar) PLUS a report/flag button — text is more tractable to auto-moderate than live speech. Rationale for moderating comments differently from battle speech: comments are permanent, public, and read by non-consenting visitors, same reasoning already applied to the username filter and the pre-publish highlight review gate.
- **Apple Guideline 1.2 (User-Generated Content) — app is explicitly covered**: as of Feb 2026, Apple clarified that random/anonymous chat apps fall under Guideline 1.2 UGC moderation rules — this names your core mechanic directly. Requirements: a method for filtering objectionable content, a mechanism for users to flag objectionable content, AND the developer must act on objectionable content reports WITHIN 24 HOURS by removing the content and ejecting the offending user. This is a hard SLA, not a vague policy statement — as a solo developer, this needs to be a real operational commitment (checking/acting on reports daily, every day, indefinitely), not just a line in the ToS. Repeated failures to comply can get the app pulled from the App Store entirely. Google Play has an equivalent (if differently enforced) UGC moderation expectation for the Android launch too.
- Apple has also added stricter age-verification language for creator/UGC apps as of late 2025/early 2026 — supports and reinforces the Play Age Signals decision already made.

## Multi-Account / Collusion Prevention — DECIDED
- **Primary defense (already in place via existing decisions)**: phone-number-based login (Firebase Auth) natively enforces one account per verified phone number — prevents the simple/cheap version of multi-accounting automatically, no extra work needed.
- **Secondary signal (V1, lightweight)**: log/flag when the same device ID is associated with multiple accounts, without necessarily blocking it outright.
- **Harder enforcement (backlog, V2+)**: device fingerprinting and pattern detection on suspiciously repeated match-ups between the same two accounts (rating manipulation/collusion) — grouped with the same infrastructure as the vote-integrity fingerprinting/anomaly-detection backlog item, since it's a related problem.

## Security & Compliance Baseline — NEW, DECIDED (developer requested security be baked into design generally)
**Covered by existing stack choices, just confirm/enable:**
- Encryption in transit (HTTPS/TLS) and at rest — default via Firebase and Agora.
- Password security — handled entirely by Firebase Auth, raw passwords never touched by app code.
- PCI-DSS avoidance — using Apple/Google IAP and a reputable processor for future cash prizes means raw card numbers are never stored, keeping mostly out of PCI-DSS scope.

**Needs deliberate action:**
- **Firestore/Realtime Database security rules audit** — sensitive fields (rating, wins/losses, points balance) must NOT be directly client-writable, or a modified/hacked client could fake wins or grant itself points. Route those specific writes through Cloud Functions (server-side logic) instead of direct client writes.
- **Firebase App Check** — verifies requests actually come from the real app, not a bot/script hitting the backend directly. Worth enabling given growth goals will make the app a bigger target over time.
- **Secrets management** — API keys (Agora, moderation APIs, etc.) go in environment config, never hardcoded or committed to the repo.
- **UK GDPR check** — since launch geography explicitly includes English-speaking countries including the UK, UK GDPR (distinct from but similar to EU GDPR) likely applies alongside CCPA — needs a specific check during the privacy policy pass. **DECIDED**: one single ToS/Privacy Policy document covering all launch regions (not separate region-specific versions) — must incorporate both CCPA and UK GDPR requirements in the single document rather than maintaining multiple versions.

## Service Status & Reliability — NEW, DECIDED
- If Agora/Firebase experiences an outage, show an in-app notice/status indicator informing users what's happening (rather than the app just silently failing/appearing broken). Could be as simple as a status check + banner, doesn't need a full public status page for V1.

## Matchmaking Queue Architecture — DECIDED
- Firestore (the primary planned database) is not well-suited to real-time "who's currently waiting to be matched" queue logic — it's built for document storage, not low-latency ephemeral state.
- **DECIDED**: use **Firebase Realtime Database** (a separate, complementary Firebase product optimized for live/ephemeral state) specifically for the matchmaking queue, while everything else (user profiles, matches, tournaments, etc.) stays in Firestore as originally planned.

## Tech Stack (Decided)
- **Frontend**: Flutter (cross-platform, Android-first build, iOS later). Chosen over React Native for native performance (important for video) and Windows-friendly Android tooling.
- **Backend**: Firebase — Auth (phone/email/password), Firestore (database), **Realtime Database (specifically for the live matchmaking queue — see Matchmaking Queue Architecture above)**, Cloud Functions (server-side logic — also used to guard sensitive writes like rating/points, see Security & Compliance Baseline), Cloud Storage (recorded videos, avatars), Cloud Messaging (push notifications), **Firebase Analytics (DECIDED — free, built into existing stack, tracks usage data needed to actually tune the many "adjust later based on real data" decisions throughout this plan: round length, points balance, tier thresholds, etc.)**. Chosen specifically because developer has no backend experience — removes need to run/manage own servers.
- **Live video**: Agora (agora_rtc_engine Flutter SDK). Chosen over LiveKit for better beginner tutorials/examples and generous free tier (~10,000 min/month).
  - **IMPORTANT ARCHITECTURE RULE**: Video provider logic MUST be isolated behind an abstract `VideoCallService` interface (see Architecture below) so Agora can be swapped for LiveKit or another provider later without touching UI/match-flow/ranking code. Do not call Agora SDK directly from UI widgets — always go through the service interface.
  - **Agora project is token-secured (confirmed via testing), NOT App-ID-only** — `joinChannel` with an empty token silently never completes (no success, no error callback — just hangs). A real per-channel token must be generated server-side (Cloud Function using Agora's token-generation library) before any real match can join a channel. A hardcoded temp token was used only to verify connectivity works end to end (Build Order step 2) — do NOT ship that pattern; wire up real Cloud Function token generation before match flow (Build Order step 3+) goes further.
  - **Android toolchain is PINNED below the project's Flutter-default versions specifically for Agora compatibility** — do not "helpfully" upgrade these without re-testing Agora:
    - AGP (`com.android.application`) pinned to **8.7.3**, not the newer default (9.0.1). AGP 9.x's stricter manifest-namespace enforcement makes `agora_rtc_engine` 6.6.3's own dependencies (`iris-rtc` vs `agora-special-full`, both declaring the same `io.agora.rtc` manifest package) a hard build failure. AGP 8.7.3 only warns.
    - Kotlin Gradle Plugin pinned to **2.1.0** (paired with the AGP downgrade).
    - `compileSdk` pinned to **36** (plain int), not 37 — this SDK environment only ships API 37 under the new `android-37.0`/`android-37.1` minor-version naming, which AGP 8.7.3 (predates that scheme) cannot resolve in any form (tried both integer and string `compileSdkVersion` overrides).
    - `permission_handler` was **removed** as a dependency — `permission_handler_android` 14.0.0 hardcodes `compileSdk = 37` with no override, incompatible with the AGP 8.7.3 pin above. Runtime camera/mic permission requests are NOT currently wired up in-app (manifest permissions are declared; local dev testing pre-grants via `adb shell pm grant`). **This needs to be revisited at Build Order step 3** (pre-match camera/mic checks) — either find a permission_handler version/alternative compatible with this toolchain, or resolve the AGP/compileSdk-37 conflict by then (may have upstream fixes by that point).
- **State management — DECIDED: Provider.** Chosen over Riverpod specifically to avoid stacking a fourth new paradigm on top of Flutter/Firebase/Agora, all being learned simultaneously — Provider has a gentler learning curve and is officially sufficient for an app of this complexity per Flutter's own docs. Migrating to Riverpod later, if ever needed, is a contained refactor, not a costly foundational change like the framework/backend picks.
- **Crash reporting — DECIDED**: Firebase Crashlytics (free, integrates with existing stack) — automatic crash detection/reporting.
- **Theming — DECIDED**: support both dark and light mode, DEFAULT to dark mode (fits social/entertainment app conventions — TikTok/Instagram/Discord all lean dark-first — and suits video-heavy content).

## Project Folder Structure
```
lib/
  main.dart
  app.dart                    // root widget, routing setup

  core/
    services/
      video_call_service.dart       // ABSTRACT interface — UI talks only to this
      agora_video_service.dart      // Agora implementation of the interface
      auth_service.dart
      age_verification_service.dart // Play Age Signals wrapper

  models/
    user_model.dart
    match_model.dart
    tournament_model.dart

  screens/
    auth/
      signup_screen.dart
      login_screen.dart
    home/
      home_screen.dart
    match/
      pre_match_screen.dart   // camera guide, lighting/audio checks
      match_screen.dart       // the actual roast battle UI, round timer, mic mute logic
      voting_screen.dart
    profile/
      profile_screen.dart
    tournament/
      tournament_list_screen.dart

  widgets/
    (reusable UI components)
```

**Design principle applied throughout**: any risky/replaceable external dependency (video provider, and eventually payment processor, push notifications, etc.) should be wrapped behind an abstract interface in `core/services/`, with screens only ever talking to the interface — never directly to a third-party SDK. This is what makes providers swappable later without a rewrite.

## Firestore Data Model (starting schema, not final)
```
users/{userId}
  - username, email, phoneNumber
  - accountTier: "spectator" | "battler"  // spectator = lightweight signup; battler = full profile/approval flow
  - ageVerified: bool (from Play Age Signals — do NOT store actual birthdate)
  - createdAt  // also used for account-age vote-weight gating (min 24-48h before full-weight votes)
  - rating: number (chess-style Elo rating, invisible plumbing — see Laugh Meter)
  - rankTitle: string (one of the 10 ranks: Average Joe...GOAT — computed from rating threshold + rankedMatchesPlayed)
  - rankedMatchesPlayed: number (used for the "minimum matches per tier" gate, separate from rating)
  - lastSeenRankTitle: string (used to detect rank-up/rank-down since last login, to trigger the popup)
  - wins: number, losses: number (ranked matches only)
  - points: number (cosmetic-unlock currency, only ever increases — separate from rating)
  - skipsUsedToday: number (resets daily, max 2-3 skips/day)
  - blockedUserIds: [array]
  - referredByUserId: string | null (who referred this user, if any)
  - referralRewardGranted: bool (prevents double-granting the referral bonus — set true only once referred friend completes approval + first match)
  - tutorialCompleted: bool (one-time onboarding gate)
  - knownDeviceIds: [array] (logged for multi-account collusion detection — see Multi-Account/Collusion Prevention; flagging only for V1, not auto-blocking)
  - recentOpponentIds: [array with timestamps] (used for repeat-opponent matchmaking cooldown)
  - isPremiumSubscriber: bool
  - freeTournamentEntriesRemainingThisMonth: number (premium perk, resets monthly)
  - avatarUrl
  - accountStatus: active/banned/flagged
  - profile: {
      profession, education, hometown, interests   // required at signup
      relationshipStatus, pets, favoriteFood         // optional
      ammoText                                       // optional free-text: embarrassing/shareable info
      photoUrls: [array, min 5 required]             // each must pass visual moderation before acceptance
    }
  - approvalStatus: pending/approved/rejected  // manual review gate for V1, see User Profile System notes

config/matchSettings  (Remote Config or Firestore doc — NOT hardcoded)
  - roundCount: number (default 3)
  - roundLengthSeconds: number (default 15)
  - countdownSeconds: number (default 5)
  - bioRevealSeconds: number (default 60)
  - perMode overrides: { exhibition: {...}, ranked: {...}, tournament: {...} }

matches/{matchId}
  - player1Id, player2Id
  - mode: exhibition/ranked/tournament
  - status: pending/in_progress/completed/disqualified
  - rounds: [ { playerTurnId, videoClipUrl, startTime } ]  // 5 entries
  - disqualifyReason: null/lighting/audio/etc (TECHNICAL quality only, not content)
  - createdAt, completedAt

votes/{matchId}/ballots/{voterId}
  - votedForPlayerId
  - timestamp
  - write-locked after 24hr voting window closes

tournaments/{tournamentId}
  - name, description
  - entryFee: number | null  // DECIDED: default/starting entry fee around $5, but must be adjustable per-tournament (admin sets fee at creation, not a fixed platform-wide constant)
  - prizeType: "points" | "cash"   // cash disabled/inactive until legally activated per state
  - prizeValue: number
  - eligibleStates: [array of state codes]  // geofencing list, must be editable config not hardcoded
  - bracketStructure, startDate, status

reports/{reportId}
  - reporterId, reportedUserId, matchId
  - reason, status: pending/reviewed/actioned
  - moderatorNotes

tournaments/{tournamentId} (extended)
  - format: "async" // rolling bracket — DECIDED, players complete their match anytime within a window, not a scheduled live event
  - bracketType: "single_elimination" // DECIDED for V1 — simpler logic, faster completion, matches async format. Double elimination flagged as a possible V2 enhancement.
  - seeding: "random" // DECIDED — chosen as most fair; means byes must be handled for non-power-of-2 entrant counts since bracket size is flexible, not fixed
  - withdrawalAllowedBeforeStart: true // DECIDED — user can withdraw + get refunded before the bracket actually starts
  - windowStart, windowEnd  // per-round deadline for async bracket play
```

## Build Order (de-risking hardest/least-familiar parts first)
1. Skeleton app + Firebase Auth (phone/email/password) + Play Age Signals check on signup.
2. Agora video call integration — bare-bones 1:1 call working between two devices, behind the VideoCallService interface. Prove this works before building anything on top.
3. Pre-match camera guide + technical quality checks (lighting/audio/framing) + explicit recording consent screen (separate step, see Legal Items section).
4. Match flow logic — round timer, per-turn mic mute/unmute, 5-second countdown transitions.
5. Community voting — 24-hour window, CAPTCHA gate, vote tally.
6. Ranking/rating system — percentile tiers, rating calculation, badge display.
7. Profile + leaderboard screens.
8. Tournament framework — admin tournament creation, prizeType field (points now, cash-ready schema), eligibleStates gating.
9. Reporting/moderation tools — in-app report button, moderator review queue.
9a. Visual content moderation — integrate nudity/explicit-action detection API (see Content Policy & Moderation section), wrapped behind its own service interface.
9b. In-app support/feedback form (see Support & Launch Strategy) — needed before any app store submission.
10. Website (separate track, can be built in parallel — doesn't block app dev).
11. Marketing automation (Instagram auto-posting of top roasts) — last, depends on having real match content. See "Auto-Editing for Highlights" note below — this needs to be built before/alongside this step, not as a separate afterthought.
12. **Private beta / soft launch** (see Support & Launch Strategy) — small group via TestFlight/Play Console internal testing, BEFORE any marketing spend goes out. Validate the core loop actually works before step 11's content pipeline needs to produce anything public-facing.

## Premium Subscription — NEW, DECIDED
Monetization approach: recurring subscription for FEATURES layered on top of the free core loop, NOT gating the core ranked/exhibition gameplay itself (ranked mode, titles, and rating stay fully free — preserves the viral prestige-chasing hook the whole ranking system was designed around). Guiding principle reaffirmed by developer: keep the app authentic, focused on giving comedians an easy platform to showcase talent — explicitly rejected pay-for-visibility (boosting a match's discovery-feed placement) as undermining that authenticity.
- **Clip download — DECIDED**: free tier gets a WATERMARKED highlight clip. Premium subscribers get the FULL, unwatermarked clip/highlight reel download — lets performers share their own wins on their own social accounts. Notable: this is one of the few paid features that also feeds the app's own growth (every share is free organic exposure), funded by the person paying for it.
- **Stats/analytics dashboard — DECIDED**: premium subscription feature. Deeper competitive data (rating history over time, win rate by opponent tier, head-to-head records, round-level breakdowns) — appeals directly to the same competitive-minded users already engaged by the ranking system.
- **Tournament entries — DECIDED**: premium subscribers get a set number of free tournament entries per month (exact number TBD); non-subscribers pay the standard per-tournament entry fee. Ties the subscription and entry-fee revenue streams together rather than having them compete for the same dollar.
- **Explicitly rejected**: paywalling ranked mode itself (undercuts viral growth hook + cold-start problem — new users need to experience the free prestige loop to want to stick around) and paying for discovery-feed visibility boosts (undermines "the funniest content rises" authenticity).
- **Legal note**: a feature-access subscription (not tied to skill/chance/prize) is NOT a sweepstakes/contest-law question like tournament entry fees are — it's a standard SaaS-style subscription, cleanly handled via Apple/Google's built-in subscription APIs.

## Friend Battles — NEW, BACKLOG (not yet built, concept only)
- Idea: let users battle a SPECIFIC friend directly (bypass random matchmaking) via an invite link/code. DECIDED: this should be FREE, not a premium feature.
- **The hook (why use this over just FaceTiming a friend)**, worked out during planning: the app provides STRUCTURE (round format/timer/mic-muting — a real judged battle, not just riffing), JUDGMENT (optional community voting gives real external "who won" validation), PRODUCTION (automatic recording + auto-edited highlight clip, vs. nothing from a plain video call), and DISTRIBUTION (a battle through the app can land in the discovery feed and plug into the platform's growth ecosystem — a private FaceTime call has zero audience by definition).
- **IMPORTANT constraint — DECIDED**: friend battles must be EXHIBITION-ONLY (not counted toward ranked rating) — otherwise this directly opens the collusion/rating-manipulation door already flagged elsewhere (two friends farming easy wins against each other for rating).
- **Community judging — DECIDED (resolves prior open question)**: friend battles SHOULD be recorded and go through community voting, same as ranked/tournament matches — this is now an explicit EXCEPTION to the general exhibition-matches-aren't-recorded rule. Rationale: community judgment is core to the "why use this app instead of FaceTime" hook (external validation), so friend battles need the recording+voting pipeline even though they stay exhibition-only for RATING purposes. Two separate things: (1) does it affect rating — no; (2) does it get recorded/voted/eligible for discovery feed — yes.
- Not yet designed: invite link/code mechanism.

## Auto-Editing for Highlights — NEW NOTE (random idea, developer flagged as likely a later-stage/website-dev item, but noted now so it's not lost)
- When matches are recorded and prepared for posting to the website/Instagram, the raw footage needs automatic editing to cut out dead space (silence, hesitation, pauses) and splice the back-and-forth turns together tightly — so the posted clip is just joke-after-joke with no lag, to maximize watch-through/engagement on social.
- Likely approach: silence/audio-level detection to auto-trim gaps, possibly combined with the existing round-turn timestamps already being recorded (rounds array with start times) to know exactly where each turn begins/ends, making it easier to auto-cut between turns cleanly rather than needing to detect silence blindly.
- Not required for V1 core match functionality — this is a marketing/content-pipeline feature, likely built alongside or after the website and Instagram auto-posting step. Flagged here so it isn't lost before that phase starts.
- **Human review before public posting — DECIDED**: auto-edited highlight clips require human review/approval BEFORE going live on Instagram/website, separate from and in addition to in-match moderation. Rationale: the public social audience never consented to the platform's content policy the way matched battlers did — an auto-editing pipeline could surface something genuinely harmful or brand-damaging out of context. Same "doesn't scale forever" caveat as manual profile approval — fine at V1 volume, will need automated scoring + spot-checks as volume grows.
- **Platform-policy screening — NEW, DECIDED (important tension resolved)**: TikTok/Instagram/YouTube each have their OWN community guidelines (typically banning slurs/hate speech) that are STRICTER than this app's internal free-speech policy — a clip fine inside the app could get the social account flagged/banned if posted as-is. DECIDED: the pre-posting human review step must specifically screen for platform-policy compliance (would this get flagged/removed by TikTok/IG/YouTube's own rules), as a DISTINCT check from the general "appropriate for a public audience" review already decided. This means some genuinely funny/legal-under-app-policy content may still need to be excluded from official social posting specifically to protect the marketing account from removal — worth being upfront that this is a real content tradeoff, not just a formality.
- **Admin/moderation tooling — DECIDED**: use the Firebase console directly for V1 (browsing/editing Firestore documents to approve profiles, review reports, mark highlight clips reviewed) rather than building a custom admin dashboard — avoids spending build time on internal tooling before it's actually needed. Revisit building a real lightweight dashboard once review volume actually becomes the bottleneck, not before. Note: reviewing highlight clip video specifically is a bit clunkier this way (opening files via Firebase Storage console) but workable at V1 volume.
- **Production quality bar — NEW, DECIDED**: highlight reels must look aesthetically pleasing/professional, not just functionally trimmed — the goal is content people genuinely WANT to post/share, not just correctly-edited footage. Concrete elements to include: burned-in captions/subtitles (important for social algorithms and muted autoplay viewing — most social video is watched without sound), a consistent branded look (intro/outro or logo watermark, consistent font/color template matching app branding), and consider background music/sound design. This is a real production-value requirement, not just a technical auto-cut task — worth treating as its own design pass, likely alongside whoever handles branding/marketing.
- **Distribution — DECIDED**: prioritize TikTok as the primary channel — for a new comedy account with no existing following, TikTok's discovery algorithm delivers the fastest organic reach for comedy content specifically and the highest median reach for small/new accounts, compared to Instagram Reels (which favors existing follower/social graph, weaker for cold-start new accounts) or YouTube Shorts. Cross-post the same vertical clip to Instagram Reels and YouTube Shorts too — minimal extra cost, YouTube Shorts specifically offers the longest content shelf life/evergreen discovery even if it's not the primary growth engine.

## First Milestone to Build Toward
A user can sign up (Firebase Auth email/password), the app checks their Play Age Signals bracket, and they land on a home screen showing "Welcome, [username]." This proves auth + age-gating + navigation work together before adding anything else.

## Open / Not-Yet-Decided Items
- State management library — DECIDED: Provider (see Tech Stack section for reasoning).
- Website tech stack — **DECIDED: Next.js**, chosen for strong first-party Firebase integration/docs, simple free deployment (Vercel), and server-side rendering (matters for SEO and for link previews when match clips get shared on social — a client-only site often renders blank to search engines/preview bots).
- Firestore security rules — not yet written (now includes: guarding sensitive fields like rating/points via Cloud Functions, see Security & Compliance Baseline).
- Exact variable K-factor values per tier band, exact rating thresholds + minimum-matches-per-tier numbers for each of the 10 ranks, and exact season soft-reset percentage — mechanics decided, precise numbers not yet set.
- Full rank-up/rank-down popup message set (10 ranks × 2 directions, with variants) — only a handful of seed examples written so far, see Ranking System section.
- Laugh Meter visual design (gauge zones, colors, naming) — concept decided, visual design not yet done.
- Report-to-ban moderation workflow specifics — not yet detailed.
- Marketing plan execution details (celebrity/comedian promo outreach, ad spend) — high-level only so far.
- Visual moderation provider not yet chosen (candidates: AWS Rekognition, Google Cloud Vision SafeSearch, Azure Content Moderator, Hive, Sightengine).
- Terms of Service / Privacy Policy — not yet drafted.
- Business entity formation — not yet done.
- Payment processor for future cash prizes — not yet selected.
- Rate limiting / daily match cap mechanism — DECIDED: no limit for V1, backlog item to revisit if bot/spam farming becomes a real problem.
- Exact video retention window length — DECIDED: 7 days.
- GOAT-tier exclusive perks — concept decided (special cosmetics/priority matchmaking/exclusive tournaments), specific perks still undecided by developer.
- Operational plan for meeting Apple's 24-hour UGC report response SLA (see App Store Compliance) — requirement identified, day-to-day process not yet defined.
- UK GDPR compliance specifics — flagged as needed, not yet researched in detail.
- Repeat-opponent cooldown duration/logic — DECIDED: 1 day ideal, falls back to allow re-match sooner if no other opponent is available.
- Business/company name — deferred, not currently blocking (see Business Entity Formation section — entity/naming decisions pushed to when real payments actually go live).
- Ban appeal flow — decided to build, UX/workflow not yet detailed.
- Vote reminder push notification cadence — decided to be periodic (not single), exact frequency/count TBD.
- Premium subscription price point and exact number of free monthly tournament entries — features decided, pricing/numbers not yet set.
- Friend Battles feature — concept, constraints, and community-judging decided (free, exhibition-only for rating, but recorded+voted); invite link/code mechanism not yet designed.
- Voting incentive point values, streak bonus amounts, and Judge track titles/thresholds — structure decided, exact numbers/titles not yet designed.
- Highlight reel branding specifics (intro/outro design, font/color template, whether to use background music) — production-quality requirement decided, visual/audio design not yet done.
- App name — not yet decided; brainstormed candidates need trademark/domain availability check.
- Quality-flag abuse detection mechanism/threshold — safeguard decided, exact implementation not yet designed.
- Daily "prime time" notification — timing/mechanism not yet designed.
- Paid ambassador/referral program — payout structure and target communities not yet designed.
- Daily/weekly quest system — content, rotation, and rewards not yet designed.
