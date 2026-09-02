# Session handoff — 2026-09-01

Point-in-time snapshot to resume work. All **decisions** live in `CLAUDE.md`
(a fresh session auto-reads it); this file is the transient "where we are /
do this next" state. Overwrite or delete once resumed.

## What was built and verified this session (all done — don't redo)

1. **The nightly "climb" tournament — DONE, all 4 phases, deployed.**
   Rolling single-elimination: join anytime → enter at 0 wins → paired only
   with same-win-count climbers → win to climb, lose once and you're out →
   wait time becomes watch/vote time → last one standing (or highest wins at
   window end) is champion. Anti-cheese is structural (a latecomer can't
   leapfrog; they climb from the bottom). Full write-up in CLAUDE.md under
   "Nightly 'climb' tournament format".
   - **Phase 1 engine** `functions/climbTournament.js` — 21 checks + 1,080
     sims (`node test/climbTournament.test.js`).
   - **Phase 2 backend** `functions/climbPlay.js` (`joinClimb`, `climbPoll`,
     `applyClimbResult` via `finalizeMatch`, `sweepClimb` scheduled every
     1 min) — 16 live checks (`node live/climbChecks.js`). Deployed.
   - **Phase 3 client** `lib/screens/tournament/climb_screen.dart`;
     `PreMatchScreen` got a `climbPairing` param; `TournamentDetailScreen`
     shows "Join the climb" and guards the bracket UI off for climb;
     `spectator.js` broadened to allow climb battles. Join+waiting state
     verified on the emulator.
   - **Phase 4 daily flip** `functions/dailyTournament.js` now creates
     `format:"climb"` with `windowStartMs`/`windowEndMs` + `climb:{climbers:[]}`.
     Deployed.
   - **Bug caught on device + fixed:** `resolveChampion` treated an EMPTY
     field as "done", so `sweepClimb` completed a fresh climb before anyone
     joined. Now an empty field is only over once the window ends (then it
     cancels). Pinned by 2 engine tests.

2. **Nightlife auto-window-skin was DROPPED** (superseded the earlier
   handoff). The app always wears the user's equipped skin now
   (`wireActiveTheme` no longer branches on `kWindowLive`). Nightlife is kept
   as an unlockable prestige skin in Appearance (alongside Neon). Note for
   later: the dev may make ALL skins paid unlocks.

3. **App-wide LIVE cue** `lib/widgets/window_live_bar.dart` — a loud red bar
   (shine sweep, blinking ●LIVE, "{NAME}·2X POINTS", white JOIN pill) above
   the tabs during the window. Replaces the dropped skin swap. Device-verified.

4. **Banner CTAs.** Metallic-gold "Join Tournament" (thin earthy-brown
   outline, no glow) + purple "Watch" on the LIVE banner; the same gold
   button labelled "Tonight's Tournament" on the pre-window banner (keeps
   "I'm in tonight"). Primary CTA renamed **"Roast a Stranger"**. Home CTA
   moved above the fold (above quests) on the physical S22.
   `lib/widgets/event_window_banner.dart`, `lib/screens/home/home_screen.dart`.

5. **Live watcher count** ("N watching") — heartbeat at
   `liveWatch/{matchId}/viewers/{uid}`, own-write-only rule (deployed),
   counted fresh within 30s. In `live_viewer_screen.dart`. NOT device-verified
   (needs a live broadcast + multiple spectators).

6. **Friend-battle challenger-can't-join bug — fixed + verified on 2 devices.**
   `getMyChallenges` now returns an `accepted` list; `ChallengeScreen` polls
   and shows "Battle now". `functions/friendBattle.js`, `challenge_screen.dart`.

7. **7 contradiction-sweep resolutions** (see CLAUDE.md "Contradiction sweep
   resolutions"): Practice exempt from the intro-video gate; GOAT flame only
   for real `rankTitle=="GOAT"`; practice-vs-stranger collapsed into solo
   practice; stale "ranked/window" copy swept to tournament framing; etc.

8. **Core-loop regression harness fixed.** The mandatory intro-video gate we
   added to `enterQueue` had silently broken `live/coreLoop.js` (its probe
   accounts had no intro → couldn't queue → STEP 1 failed). Gave probe
   accounts a placeholder `profile.introVideoUrl`. Now **22/22 green**.

## Verification status at session end

- Pure suites: climb engine (21+1080 sims) ✓, daily plan (8) ✓, syntax ✓.
- `node live/scheduledJobScan.js` → **15/15** (incl. `sweepClimb`), coverage
  complete ✓.
- `node live/coreLoop.js` → **22/22** ✓ (finalize routing for climb didn't
  disturb ordinary ranked/tournament finalize).
- `node live/climbChecks.js` → **16/16** (from earlier this session; finalize
  routing unchanged since).

## DRY RUN DONE (2026-09-01) — the climb ran end-to-end on two real devices

Emulator (`emulator-5554`, DryRunA) + physical S22 (`RFCT4038EEZ`, DryRunB)
over **Wi-Fi adb**. Full flow proven: pairing across two real clients →
consent → pre-match → bio reveal → ready → **real battle with bidirectional
video, the 30s warmup, all 3 rounds** → "Match complete!". Three bugs found;
one fixed. See CLAUDE.md's climb section for the full write-up. Both devices
were left with the **debug** build installed and logged in as DryRunA/DryRunB
(placeholder intros). Test tournaments/scripts/screenshots were cleaned up.

## RESOLVED SINCE THE DRY RUN (2026-09-01, all deployed + verified)

- **Looping-video background audio (the phone playback incident): FIXED.**
  `LoopingVideo` + `MatchClipPlayer` now pause on background via
  `WidgetsBindingObserver`. All server recordings the phone could loop were
  also deleted (0 remain; GCS soft-delete 7-day retention noted, not disabled).
- **Gauntlet TIE now advances BOTH climbers** (was: stranded them). Pure
  `applyTie` + `applyClimbTie` + finalize routing. Champion still crowned at 7pm.
- **Gauntlet wins MOVE hidden Elo** (they already did for present players via
  live ratings; now also STAMPED at creation so a departed opponent still
  counts). A tie moves no Elo.
- **Rematch-collision bug the tie rule exposed: FIXED** - climb match ids are
  now unique nonces (were deterministic per pair, which collided on a rematch).
- Verified: engine 34/34, `climbTieChecks` 11/11, `climbChecks` 16/16,
  `climbForfeitChecks` 7/7, `coreLoop` 22/22. Dart analyze clean.

## DO THIS NEXT (in priority order)

0. **External (developer's action):** create a Google Play Console account
   ($25) + decide on a business entity - blocks all IAP/monetization. And the
   guest-judge / super-judge feature is design-only so far (write up a
   transparent, event-scoped, prize-safe spec before building).

1. **The forfeit-sweep bug is FIXED (2026-09-01), deployed + live-verified.**
   `climbForfeitDecision` in `climbTournament.js` now keys the sweep on
   `readyPlayerIds` (both readied = battle in progress → never forfeited until
   a 25-min crash window) and recent `lastSeenAt` presence, instead of the
   never-populated `arrivedAt`. 30 pure checks + 7 live checks
   (`live/climbForfeitChecks.js`) + climbChecks 16/16 + scan 15/15. Server-only
   change; deployed. **2-DEVICE DRY RUN DONE + PASSED**: a full climb battle
   (emulator + S22) played through all 3 rounds to a **clean "Match complete!"
   with NO completeMatch INTERNAL** (the exact error the bug caused); match
   settled `completed`. Fix confirmed on real devices.
   - The TIED-climb-match strand it found is now FIXED (both advance) - see
     the RESOLVED block above.

2. **The -102 channel bug is already FIXED + verified live** (climb matchId
   shortened to a 24-hex hash; deployed; climbChecks 16/16). Nothing to do.

3. **DONE this session:** the S22 gesture-bar occlusion (tutorial / consent /
   pre-match / bio-reveal + report/support/banned forms) and the pre-match
   mic-gate calibration (peak-hold, threshold 10, "a little louder" feedback)
   are both fixed and phone-verified. The gauntlet copy nits ("opponents",
   "Enter the gauntlet", "Win to advance") are done too.

4. **RESOLVED: climb wins DO move hidden Elo** (see the RESOLVED block above).

## WEBSITE (done this session, in parallel — see below)
A subagent reskinned the site to Comedy Night (Fraunces + Inter), built a
professional homepage, and added an interactive `/demo` clickable-phone
prototype (Home / Pre-match / Opponent / Battle / Vote / Sixes & Sevens).
`npm run build` passes. NOT deployed — preview with `npm run dev` in
`website/`. All changes confined to `website/`.

## Loose ends (backlog, not blocking)

- `rebuildHallOfFame` scheduled job still runs + writes an empty `hallOfFame`
  doc nothing reads (Hall of Fame tab was removed). Un-deploy + remove from
  `index.js` and `scheduledJobScan.js` when convenient.
- No-show penalty for "I'm in tonight" — deferred until real no-show volume;
  must come from spendable `pointsBalance`, only if the tournament ran, small
  + disclosed.
- Performer-facing crowd-energy count — deferred to the gifting/heckle work.
