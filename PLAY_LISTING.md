# Google Play Console — paste-in materials

Draft store-listing text, content-rating answers, and Data Safety answers for
The Bully League, derived from CLAUDE.md's decisions. **Everything here is a
functional draft, not lawyer-reviewed** — the same standing caveat as the
`/legal` page. Tune the copy to taste; the compliance answers should stay
accurate to what the app actually does.

Console UI changes constantly, so this file is the CONTENT to paste, not a
click-by-click walkthrough. Ask me to pull Google's current official steps for
whichever specific screen you're on.

---

## 0. The critical path (why order matters)

A new personal account must run **closed testing with 12+ testers opted in for
14 continuous days** before you can apply for production. **That 14-day clock is
the long pole.** So the goal of the first sitting is narrow: get the AAB onto a
**closed testing track** and get **12 testers opted in** — polish the pretty
store assets afterward, in parallel with the clock running.

Rough sequence (policy-level; I'll fetch exact current screens on request):
1. Create the app (name, default language English (US), app not game — see note).
2. Set up the **Closed testing** track → create a release → upload the AAB.
3. Add testers (email list or a Google Group) and share the opt-in link.
4. Complete the required declarations so the track can go live: **App access**,
   **Content rating**, **Data safety**, **Target audience & content**, **Ads**,
   **Government/financial** declarations, **Privacy policy URL**.
5. Once 12 testers are opted in and 14 days have passed, **apply for production**.

> "App or game?" — pick **App**. It has competitive/ranking elements but it is a
> UGC social/entertainment app, not a game; the game category invites a
> different review lens and rating flow. (Your call, but App is the better fit.)

---

## 1. Store listing

**App name** (max 30 chars): `The Bully League` (16)

**Short description** (max 80 chars):
`Live 1-on-1 roast battles with strangers. The crowd votes who won. 18+.` (70)

**Full description** (max 4000 chars):

```
The Bully League is a live 1-on-1 roast battle app. Get randomly matched with a stranger, trade jokes on camera in a timed battle, and let the community decide who won.

HOW IT WORKS
- Get matched 1-on-1 and study your opponent's intro video for ammo.
- Battle in fast timed rounds - one mic live at a time. Land your jokes.
- The crowd watches and votes. The funniest one wins.
- Climb a real skill-based ladder, from Average Joe all the way to GOAT.

THE NIGHTLY TOURNAMENT - SIXES AND SEVENS
Every night from 6-7pm Pacific the whole league shows up at once for a live bracket tournament. Win, and you climb. Lose, and you're out. It's the busiest hour of the day and the fastest way to find a battle - come get someone.

JUDGE THE BATTLES
Not in the mood to battle? Watch and vote. Your calls decide the ladder, and judging earns you points toward your own progression.

BATTLE YOUR FRIENDS
Challenge anyone by username for an unranked battle - recorded and judged by the crowd, just for the bragging rights.

18+ ONLY. FREE SPEECH BY DESIGN.
This is a comedy platform. Hard-hitting, offensive, no-holds-barred roasting is the entire point, and you agree to that when you sign up. You must be 18 or older to use the app. What is NOT allowed: hate used to genuinely demean people rather than for comedy, targeted harassment beyond the battle, and anything explicit on camera. Report it and we act on it.

RECORDED AND SHAREABLE
Ranked and tournament battles are recorded, and the best moments can become highlight clips. You give explicit consent before every battle, and you can remove your own clip.

Bring your A-game. The crowd is merciless.
```

**Graphics you still need to produce** (Play requires these before a listing
goes live):
- **App icon** 512x512 PNG (32-bit, with alpha).
- **Feature graphic** 1024x500 PNG/JPG.
- **Phone screenshots** — min 2, up to 8 (16:9 or 9:16). *Real device
  screenshots were captured during the 2026-09-01 scan (Home, Ranks, the
  flip card, Judge, etc.) in the scratchpad — usable as-is for a closed test,
  worth polishing before production.*
- (Optional) short promo video.

**Category:** Entertainment (or Social). **Contact email + privacy policy URL:**
`https://the-bully-league.vercel.app/legal`

---

## 2. Content rating (IARC questionnaire)

Answer honestly — an 18+ UGC video app with permissive language WILL land a
**Mature / Adult (17+/18+)** rating, which is exactly what you want given the
hard age gate. Key answers:

- **Category:** Social / Communication (or Entertainment) — NOT a game.
- **Violence:** None depicted by the app itself.
- **Sexuality / nudity:** None depicted by the app; automated nudity detection
  auto-ends matches and files a report.
- **Profanity / crude humor:** **Yes — frequent/strong.** Roasting is the point.
- **Controlled substances:** May be referenced in user speech; not depicted.
- **User-generated content / user-to-user interaction:** **YES.** Users are
  randomly matched for **live video** with strangers, can communicate, and
  share user-generated content publicly. This is the load-bearing answer — it
  triggers the social/UGC classification and the moderation questions below.
- **Users can interact / share content:** Yes. **Share physical location:** No
  (hometown is self-typed text, not device location). **Share personal info:**
  Users choose what to put in their profile.
- **Moderation:** in-app reporting on every clip + report review acted on within
  24h; automated visual (nudity) moderation; username filter.

---

## 3. Data safety form

**Does your app collect or share user data? YES.**
**Is all data encrypted in transit? YES** (Firebase/Agora TLS).
**Do you provide a way to request data deletion? YES** — in-app "Delete my
account" flow (Profile → Delete account).

Processors (service providers processing on our behalf, not third-party
"sharing"): Google Firebase (auth, database, storage, messaging, crash),
Google Cloud Vision (photo/video nudity screening), Google Cloud Speech-to-Text
(clip captions), Agora (live video + recording), Cloudflare Turnstile (CAPTCHA).

Data types to declare (Collected; purpose = App functionality + Account
management unless noted; none used for advertising; none "shared"):

| Data type | Collected | Notes |
|---|---|---|
| Email address | Yes | Account. Required. |
| Phone number | Yes | Account / anti-fraud. Required. |
| User IDs | Yes | Account (uid, username). |
| Name / other profile info | Yes (optional) | Profession, education, hometown (text), interests, "ammo" — user-entered, optional. |
| Photos | Yes (optional) | Profile photos (feature exists; unenforced in beta). |
| Videos | Yes | Intro video + recorded ranked/tournament battles. |
| Voice or sound recordings | Yes | Match audio (recorded battles). |
| Messages / other UGC | Yes | Roasts (video/audio), ammo text, reports. |
| App interactions | Yes | Matches, votes, ranking activity. Analytics. |
| Crash logs / diagnostics | Yes | Crashlytics. |
| Device or other IDs | Yes | FCM push token; device id logged for multi-account/collusion detection. |

**NOT collected:** precise or approximate **device location** (hometown is
free text, not GPS); payment info (no IAP live yet); contacts; browsing history;
health; SMS. Do NOT declare a birthdate — the app stores only an 18+ boolean
from Play Age Signals (data minimization).

Mark video/audio as **required** (you can't battle without them) and profile
text/photos as **optional**.

---

## 4. App content declarations

- **Target audience & content:** age group **18+ only**. Confirm the app is not
  designed for or appealing to children (this pairs with your Play Age Signals
  hard gate). Expect a follow-up on the "designed for families" answer: **No.**
- **Ads:** **No ads** (V1).
- **Government app:** No. **Financial features:** No (no real-money features
  live — points only; the entry-fee/cash-prize framework is inactive schema).
- **News app:** No. **COVID contact tracing:** No.
- **App access:** all functionality is behind sign-in — provide these
  **review-login credentials** (a dedicated demo account, already created, with
  an approved intro video so the intro-gate doesn't block it):
  - **Email:** `play-review@thebullyleague.app`
  - **Password:** `BullyReview#2026`
  - Note for the reviewer: matchmaking needs a live opponent, so a solo
    reviewer can browse Home / Judge / Ranks / Profile and the moderation
    (report) tools, but cannot complete a battle alone.

---

## 5. What I can hand you next

- The **AAB** is building now → `build/app/outputs/bundle/release/app-release.aab`.
- Say the word and I'll: create a **dedicated review/demo account** (with an
  approved intro video so Google's reviewer isn't blocked by the intro gate),
  and pull **Google's current official steps** for whichever Console screen you
  hit first.
