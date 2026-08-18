/**
 * What judging earns beyond points (CLAUDE.md's "Non-points rewards for
 * voting" decision, 2026-08-18: priority matchmaking AND extra skips with
 * a hard daily ceiling).
 *
 * WHY ANY OF THIS EXISTS. Votes are the scarce resource the ladder runs
 * on - rating only moves as far as a match is actually judged - and
 * points are a weak motivator for exactly the competitive players whose
 * votes matter most, because they care about the ladder rather than about
 * a balance. Both rewards here are deliberately USEFUL to somebody who
 * will never spend a point.
 *
 * THE CEILING ON SKIPS IS NOT A NICETY, IT IS THE WHOLE DESIGN. Skips
 * exist to be scarce: the daily cap is what stops opponent
 * cherry-picking, which corrupts ranked and is a collusion vector. And
 * skips are worth MORE to a rating-manipulator than to an honest player -
 * someone farming rating specifically wants to dodge strong opponents. So
 * if voting could mint skips without a ceiling, a determined user votes
 * ten times and has effectively unlimited dodges, reintroducing precisely
 * the problem the cap prevents.
 *
 * DELIBERATELY NOT DONE: increasing a frequent voter's VOTE WEIGHT. It is
 * the obvious-sounding reward and the wrong one - it concentrates
 * influence over match outcomes in a small group and is straightforwardly
 * gameable. Reputation-weighted voting is filed under V2 vote integrity
 * and must not arrive through the incentives door.
 */

/** Votes needed for one earned skip. */
const VOTES_PER_EARNED_SKIP = 3;

/** The most a day of judging can ever add. */
const MAX_EARNED_SKIPS = 2;

/**
 * The hard ceiling on skips from all sources combined.
 *
 * Stated as its own constant rather than left implicit in the arithmetic,
 * because it is the number that actually protects ranked. If the base
 * allowance is ever raised, this must be reconsidered deliberately rather
 * than drifting upward as a side effect.
 */
const HARD_TOTAL_SKIP_CAP = 5;

/** Effective queue-time bonus per vote cast today. */
const PRIORITY_MS_PER_VOTE = 15 * 1000;

/**
 * And the most it can ever add up to.
 *
 * DELIBERATELY WELL UNDER standingChallenge.js's 90-SECOND THRESHOLD,
 * and that relationship is the whole reason this stays a tiebreak. A
 * queue entry becomes a STANDING challenge after 90 seconds and is
 * then sorted behind every live waiter regardless - so the live
 * candidates competing on wait time span at most that 90 seconds. A
 * bonus of two minutes, which is what this was first set to, therefore
 * exceeded the entire window it operated in and made an active judge
 * beat EVERY live non-judge outright. That is a separate priority
 * queue wearing a tiebreak's clothes.
 *
 * At 45 seconds a judge goes ahead of anyone who arrived within 45
 * seconds of them, while someone who has genuinely been waiting longer
 * than that still wins. Pinned by a test against the real constant.
 */
const MAX_PRIORITY_MS = 45 * 1000;

/**
 * How many votes today count toward these rewards.
 *
 * KEYED TO THE SAME DAY THE SKIP ALLOWANCE USES (UTC), deliberately, even
 * though vote POINTS are keyed to the Pacific day. Two different day
 * boundaries would let somebody earn skips against one day and spend them
 * against another: earn at 4pm Pacific, watch the UTC day roll at 5pm, and
 * arrive at a fresh base allowance still holding the earned ones. One
 * boundary, so they expire together.
 */
function judgeVotesToday(user, dayKey) {
  if (!user || user.judgeDayKey !== dayKey) return 0;
  const n = Number(user.judgeVotesToday);
  return Number.isFinite(n) && n > 0 ? Math.floor(n) : 0;
}

/**
 * Extra skips earned by judging today.
 *
 * Derived from the vote count rather than stored as its own balance, so
 * there is no second number to keep in step and nothing to reset - a new
 * day changes the key and the earned skips are simply gone, which is what
 * "expire with the daily reset rather than banking up" means.
 */
function earnedSkips(user, dayKey) {
  const votes = judgeVotesToday(user, dayKey);
  return Math.min(MAX_EARNED_SKIPS,
      Math.floor(votes / VOTES_PER_EARNED_SKIP));
}

/**
 * The caller's whole skip allowance today, base plus earned, clamped to
 * the hard ceiling.
 */
function skipAllowance(user, dayKey, baseAllowance) {
  const base = Number.isFinite(Number(baseAllowance)) ?
    Number(baseAllowance) : 0;
  return Math.min(HARD_TOTAL_SKIP_CAP, base + earnedSkips(user, dayKey));
}

/**
 * The queue-time bonus an active judge gets when opponents are chosen.
 *
 * EXPRESSED AS WAIT TIME ON PURPOSE, so it rides the existing
 * longest-waiting tiebreak rather than adding a new axis to matchmaking.
 * It is applied ONLY to opponent selection, never to the tier-widening
 * clock: widening decides how skill-appropriate a pairing is allowed to
 * be, and rewarding judging with worse-matched opponents would be a
 * punishment dressed as a perk.
 *
 * It also self-limits in the only way that matters. When the pool is
 * thick, pairing is near-instant and two minutes of notional wait changes
 * nothing; when the pool is thin - which is when being paired first is
 * actually worth something - it decides the order. Nobody is ever
 * excluded, only re-ordered, so this can never starve a non-judge.
 */
function priorityBonusMs(user, dayKey) {
  const votes = judgeVotesToday(user, dayKey);
  return Math.min(MAX_PRIORITY_MS, votes * PRIORITY_MS_PER_VOTE);
}

/**
 * The fields to write after a vote is cast.
 *
 * Returned rather than written so the caller can fold it into whatever
 * transaction it already has, and so the whole rule is testable without
 * Firestore. Written ABSOLUTELY rather than with an increment, because a
 * new day has to reset the count - an increment alongside a new day key
 * is exactly the bug the vote reminders hit at a day boundary.
 */
function judgeVoteUpdate(user, dayKey) {
  return {
    judgeDayKey: dayKey,
    judgeVotesToday: judgeVotesToday(user, dayKey) + 1,
  };
}

module.exports = {
  judgeVotesToday,
  earnedSkips,
  skipAllowance,
  priorityBonusMs,
  judgeVoteUpdate,
  VOTES_PER_EARNED_SKIP,
  MAX_EARNED_SKIPS,
  HARD_TOTAL_SKIP_CAP,
  PRIORITY_MS_PER_VOTE,
  MAX_PRIORITY_MS,
};
