# Launch watchlist

Things to check, tune or switch on **once real people are using the app**.
Written 2026-08-17. Everything here is either a guess that needs data, a
switch that ships off, or something that could only ever be verified with
real users.

This file is the canonical list — it lives beside the code so the values
it quotes can't drift out of sync. Tick items off as they're settled.

---

## 0. Before anyone can use it at all

- [ ] **Google Play Developer account** ($25, one-off). Needs your own
      Google account — nobody can create it for you.
- [ ] **Play Console listing + internal testing track**: content rating
      questionnaire, data safety section, upload the signed AAB, invite
      testers by email.
- [ ] **Real legal review** of the Terms/Privacy page. It is live at
      `/legal` and marked on the page itself as a non-lawyer-reviewed
      placeholder. It is accurate to the product, which is a different
      thing from being sound.
- [ ] **Trademark search on "The Bully League"** before the name gets
      valuable. There is an unrelated `@thebullyleague` Instagram account
      calling itself "TBL Official" — if that is a real business using the
      name in commerce, it may have common-law rights that conflict.

---

## 1. Switches that ship OFF

Nothing below is live today. Each is a deliberate decision to flip, not an
oversight.

| Switch | Where | Now | What flipping it does |
|---|---|---|---|
| Paywall | `config/monetization.enabled` | `false` | Enforces the whole model: free players get ranked during the window only. **Until this is `true`, nothing else in section 2 can be observed** — everyone already has full access, so day passes, trials and lapsed states are all inert. |
| Day passes | `config/pointsSettings.dayPassEnabled` | `true` | The kill switch. One edit removes the sink if it eats subscriptions. |
| Service notice | `config/serviceStatus.active` | `false` | Your only broadcast channel. See section 5. |

> **The paywall switch is the big one.** Flipping it is the moment the
> economy starts existing. Do it deliberately, and expect to re-read
> section 2 that week.

---

## 2. Numbers that are guesses

All config-tunable without a release. All chosen so the *ratios* feel
right, not because the absolute values are known to be correct.

### Day pass — 500 points
- **Watch:** how often people buy one, and whether buyers ever convert to
  subscribers.
- **Bad sign:** someone buying a pass every few days and never
  subscribing. That's the sink substituting for the product rather than
  sampling it.
- **Do:** raise the price, or pull it with `dayPassEnabled: false`.
- Currently ≈ **3 days** of committed play, or **8 days** of judging alone.
- Deliberately priced high from the start: raising a price later is the
  most damaging pricing move available, lowering one reads as generosity.

### Vote points cap — 10/day
- **Watch both directions.** Too low and honest judges stop being paid for
  real work; too high and it's still farmable.
- **Bad sign (too low):** engaged users regularly hitting the cap.
- **Bad sign (too high):** vote counts far above what the userbase could
  plausibly watch, or clip quality that doesn't track vote counts.
- **Do:** tune `votePointsPerDay`. If farming persists at a sane cap, build
  the **watch-time gate** (below) — it's the second lever and it's designed
  but not built.

### Clip price — 250, first one free
- **Watch:** whether people actually post the clips they get. Clips are
  distribution; a clip nobody posts is a cost with no return.
- **Bad sign:** high grant rate, no social spread.
- **Do:** clips being marketing argues for *cheaper*, not dearer.

### Other economy numbers
| Value | Now |
|---|---|
| Match played / won / vote / daily streak | 10 / 25 / 5 / 15 |
| Referral (battler / spectator) | 100 / 25 |
| Event-window multiplier | 2× |
| Trial length | 14 days |
| Subscription price | $6.99/mo, $39.99/yr — **never tested, no IAP exists** |

### Match format
| Value | Now | Note |
|---|---|---|
| Rounds / turn length / countdown | 3 / 15s / 5s | |
| Bio reveal | **600s (10 min)** | Long by design; safe because presence heartbeats release an absent opponent. Watch whether people actually use the time or just tap Ready. |
| Event window | 18:00–19:00 Pacific | Name and hours both provisional. |

### Rank thresholds and K-factors
Still explicit placeholders in `functions/rating.js` (`RANK_TIERS`,
`GOAT_POOL_SIZE`, K breakpoints). **These need real rating distribution
data before they mean anything.** Starting rating is 1200 and should land
mid-ladder, not at the bottom — check that it does.

---

## 2b. Beta pass bar — "no hard blockers"

Your call. It's a **floor rather than a bar**: cheap to hit and it tells
you the app works, not that the loop does. Worth being clear-eyed that
clearing it says nothing about whether people come back, whether matches
get judged, or whether anyone shares a clip.

Made concrete so it's tickable:

- [ ] Someone can sign up, complete the tutorial and reach a match without
      help.
- [ ] Two people can complete a full ranked battle on real devices, and it
      settles as `completed`.
- [ ] That battle gets recorded, rendered, and is watchable in the Judge
      tab.
- [ ] A third person can judge it, and the result finalizes with a winner.
- [ ] Rating, wins/losses and points all move as expected afterwards.
- [ ] Nothing on Home, Judge, My Battles, Ranks or Profile errors or
      shows a control that doesn't work.
- [ ] A report submitted from the Judge feed lands in `reports`.
- [ ] Someone can delete their account and it actually goes.

> **A path with no live check is a path nobody is checking.** `castVote`
> was found throwing on every call — voting was dead in production —
> because the core-loop regression writes ballots directly to bypass the
> CAPTCHA and therefore never called it. The suite was green throughout.
> When ticking the list above, exercise the real path, not a proxy for it.

---

## 3. Never verified with real users

These are not "probably fine" — they are genuinely unknown.

- [ ] **CAPTIONS ON REAL SPEECH.** Every test match transcribed to
      **silence**, because emulators publish no audio. The grouping,
      styling and burn-in are verified with injected cues; the
      transcription itself has never produced a word. **This is the core
      of the flagship paid feature.** One match on two physical devices
      with real microphones settles it.
- [ ] **Watermark legibility on real camera footage.** Only ever seen
      against a bright emulator test pattern. It's white at ~45% opacity
      with a dark outline — needs one look at a real face in real light.
- [ ] **A full two-device match since the recent changes.** Entitlement
      checks, signup ordering, rules and account deletion all moved. The
      server path is regression-tested (`functions/live/coreLoop.js`), but
      two real devices playing a video match end to end has not been
      re-run.
- [ ] **Recording cost at real volume.** ~$0.035 per recorded match. The
      Agora free tier is ~10,000 min/month shared across calling and
      recording ≈ **1,300 recorded matches/month**.
- [ ] **Whether anyone turns up to Sixes and Sevens.** The whole liquidity
      strategy rests on it.

---

## 4. Operational commitments that start on day one

- [ ] **Apple Guideline 1.2: act on reports within 24 hours.** Not a
      guideline — a hard SLA, and repeated failures can get the app pulled.
      The `reports` collection is currently empty; check it **daily** via
      the Firebase console once real users exist. There is no admin
      dashboard by design.
- [ ] **`supportRequests` and `banAppeals`** need the same daily glance.
- [ ] **Profile photos and manual approval are unenforced** (your call for
      the beta). Consequences to expect: bio reveal is text-only, and
      directory cards have no photo. Revisit when signup volume is real —
      manual approval does not scale past what one person can review.

---

## 5. If something breaks

Set `config/serviceStatus`:
```
active: true
severity: "info" | "warning" | "outage"
message: "Video is having a rough time. We know."
updatedAtMs: <current epoch millis>   ← REQUIRED, or nothing shows
```
It appears above every screen. Without `expiresAtMs` it clears itself 24h
after `updatedAtMs`, so a forgotten banner can't become permanent. Also
usable as a broadcast ("no Sixes and Sevens tonight").

---

## 6. Known gaps that only bite with real users

Each is a deliberate accepted limitation, not a bug. Listed so that if it
happens, you know it was foreseen and roughly what the fix is.

| Gap | Fix if it happens |
|---|---|
| No homoglyph defence on usernames (`PIayer` vs `Player`) | Claim a second aggressively-normalised key — costs blocking legitimately distinct names like `Mark`/`M4rk` |
| No "who can challenge me" setting | Blocks + 3-outstanding sender cap + 1h expiry are the current defence |
| A clip published *after* voting closed can't be preference-opted-out — only reported as harm | One config change |
| Daily **skip** allowance resets on UTC midnight (5pm Pacific), unlike everything else | Switch to the Pacific day key the streak and quests already use |
| No watch-time gate before voting | Designed, not built — the second lever against vote farming |
| Push notifications land on FCM's fallback channel, showing as "Miscellaneous" in system settings | Needs native channel creation |
| Matchmaking pairing transacts on the whole per-mode queue node | Shard by tier band when concurrency makes it hurt |
| Tournament entries are points-only | Entry fees carry cash value — re-examine minting them before cash prizes activate |

---

## 7. Cost tripwires

| Meter | Free allowance | Roughly |
|---|---|---|
| Agora (calling + recording, shared) | 10,000 min/month | ~1,300 recorded matches |
| Speech-to-Text | — | ~$0.066 per captioned clip — the dominant clip cost |
| Render (ffmpeg) | — | ~$0.003 per clip |
| Firestore writes | 20k/day | Scheduled jobs are fixed-cost; client polling is not |

Captioning is rationed to a weekly top-10 (hard cap 15) precisely because
it is the expensive stage. **If clip costs spike, look at how many are
being captioned before anything else.**

A viral day of 5,000 recorded matches costs roughly **$175** — the free
tier is small but the paid rate is cheap. That is a very different risk
profile from what the original planning assumed.

---

## 8. First-week questions worth asking deliberately

- Does anyone open the app when there's nobody online — and do they use
  solo practice or leave?
- Do friend challenges get used more than random matchmaking? (With a
  small group they should.)
- Do matches get judged at all, or do they close unjudged? Vote confidence
  means an unjudged match barely counts.
- Does anyone finish a battle and immediately want the clip?
- What's the first thing someone asks you that the app should have
  answered itself?
