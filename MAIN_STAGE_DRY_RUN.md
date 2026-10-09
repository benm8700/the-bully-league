# Main Stage finals — dry run runbook

This is the first real-device test of the weekly-finals live flow: the
chess-clock battle screen and the judges' room. Everything underneath it is
already verified against the live backend (see the checklist at the bottom);
what's never run on real devices is the battle + judging on screen.

You need **three accounts** across your devices:
- **2 battlers** — the two phones/emulators that will actually fight.
- **1 judge** — a third account (another device, or the same person switching
  accounts after the battle). With a one-judge panel, a single vote settles
  the battle, so one judge is enough for the test.

The launch flag (`config/tournament.enabled`) does **not** need to be on — the
battle/judge callables aren't gated on it. The priming script writes the
tournament directly.

## 1. Stage it (from `functions/`)

```
node live/primeMainStageDryRun.js <battler1> <battler2> <judge>
```

Each argument is a **username** (case-insensitive) or a raw uid. Example:

```
node live/primeMainStageDryRun.js MedalMoto DryRunB JudgeAcct
```

It prints exactly who it placed where and the on-device steps.

## 2. On the devices

- **Both battlers**: open the app → Home shows a gold **"The Main Stage is
  LIVE"** banner → tap it → **"Play your match"** → recording consent → the
  camera/mic check → the chess-clock battle.
  - The battle only starts (and your clock only begins) once **both** of you
    are in — whoever arrives first sees "Waiting for your opponent… your clock
    has not started."
  - Each of you talks on your own 1-minute clock (it only runs while you hold
    the floor; unused time banks). **Yield** passes the floor; **Interrupt**
    (2 each) cuts in and starts your own clock. When both clocks hit zero the
    battle ends and it says "the judges decide."
- **Judge**: open the app → Home shows **"The Main Stage is LIVE"** → tap it →
  **"Open the judges' room"** (this button appears once a battler has started
  the match) → you'll see the two battlers live → tap the winner to cast your
  open vote. That one vote settles it and fills the bracket.
  - You can open the room and vote **during or after** the battle — voting no
    longer depends on the live video, so arriving late still works.

## 3. Tear it down (from `functions/`)

```
node live/teardownMainStageDryRun.js
```

Removes the staged tournament, the two bench accounts, and the battle match,
and **restores the two battlers' rating / wins / losses** from the snapshot it
took (a dry-run battle does move Elo). It does not reverse points / quest
progress (those only rise and the beta resets at launch).

## What to watch for (the unverified bits)

- Both devices actually show each other's video in the battle.
- The clock gate: the first arrival's clock does NOT start until the opponent
  joins.
- Mic follows the floor — only the person holding the floor is heard.
- Interrupts: tapping Interrupt takes the floor and starts your clock; 2 max.
- The judges' room shows the live tally climbing and lands on the verdict.
- After the verdict, the bracket matchup shows the winner.
- Known gap (not a bug to chase): a Main Stage battle is **not recorded**, so
  there's no highlight clip of the finals yet — unlike ordinary ranked
  matches. Flagged as a follow-up.

## Already verified against the live backend (no need to re-test)

- `verifyDryRunStaging.js` — the staging + the exact callables the devices
  call (startMainStageBattle ×2, the real completeMatch, the judge vote,
  bracket advance, teardown + restore): **8/8**.
- `mainStageChecks` 8/8, `mainStageSettleChecks` 8/8 (incl. a judge spectating
  a live mainstage battle), `mainStageForceCloseChecks` 6/6,
  `weeklyQualifierChecks` 8/8, `coreLoop` 22/22, `callableHealthScan` 72/72,
  `scheduledJobScan` 21/21, `rulesAuditChecks` 11/11.
