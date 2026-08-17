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

Needs `website/.env.local` for Admin SDK credentials.
