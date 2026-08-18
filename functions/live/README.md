# Live checks

Scripts here run against the **real, deployed backend and real Firestore**,
not an emulator. They are the counterpart to `functions/test/*.test.js`,
which are pure and prove logic in isolation.

Both exist because this project has repeatedly been bitten by failures that
only appear in the seam between things:

- `publishOnlineCount` threw on every run because `MODES` was never
  exported. Its pure helper had 12 passing tests; the break was in the
  import.
- `voteReminders` needed a composite index that did not exist. The query
  would have thrown every run and been swallowed by the scheduler's own
  try/catch, showing up as a job that silently did nothing.
- `FieldValue` was used but never imported in `matchFinalization.js`.
  `require()` succeeded, because the reference is only reached at runtime
  inside a transaction — every ranked finalization would have thrown.

A green deploy proves none of this. Only running the thing does.

## coreLoop.js

The full critical path, end to end:

```
queue -> pair -> complete -> vote -> finalize
      -> rating, wins/losses, points (both numbers), rating history,
         rank change, entitlement, clip eligibility, judge feed
```

**Run it after touching anything on a shared path** — `enterQueue`,
`pollMatchmaking`, `completeMatch`, `finalizeMatch`, `awardPoints`. Those
are each depended on by several features, and a regression there breaks
the whole app regardless of how good anything built on top of it is.

```bash
cd functions
node live/coreLoop.js
```

It creates three throwaway accounts, plays a real match through the real
callables, asserts every downstream effect, and **deletes everything it
made** — accounts, match, ballots, and the `ratingHistory` /
`pointsLedger` subcollections underneath — in a `finally` block, so a
failure part-way through still cleans up.

It also asserts the **referral hook fires from inside completeMatch** - the
unit test calls the grant function directly and would not notice the hook
being removed or never wired up. That assertion was deliberately checked
by sabotage: with the attribution removed it fails, so it is not passing
for an unrelated reason.

## Known coverage gap

The ballot is written directly to Firestore rather than through
`castVote`, because voting requires a Turnstile solve or an existing vote
session and Turnstile deliberately refuses automated browsers. That is the
anti-bot protection working as intended, so the vote callable - and with
it the daily voting streak - cannot be driven from a script and is
covered by its own unit and live checks instead.

Needs `website/.env.local` for Admin SDK credentials.

## Health scans

Two scans that exist because of failures this project has actually had,
not hypothetical ones. Both are safe to re-run and worth running before
any release.

- **`scheduledJobScan.js`** - runs every scheduled job against real
  Firestore and reports which ones throw. Three scheduled functions have
  been silently dead in production here (the `MODES` export, the
  `voteReminders` index, and `finalizeExpiredMatches`, which had therefore
  never settled a single ranked match). Every one had a green deploy, a
  firing schedule, and a try/catch that ate the error. A unit test cannot
  see any of it, because the break is in the seam between the function and
  the database.
  Note it does real work - settling, pushing, purging - so run it
  deliberately.

- **`callableHealthScan.js`** - probes every deployed callable and reports
  any whose Cloud Run IAM binding is missing. That binding failed on four
  separate functions in a single day. The symptom is a 401 with Google's
  HTML page returned *before* the function runs, so every real user is
  rejected and the function's own auth check never executes. The scan
  distinguishes it from a healthy callable's own JSON 401 by checking the
  response shape rather than the status code. A plain redeploy fixes it.
