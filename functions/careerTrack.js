/**
 * The career track: a second ladder built on points rather than rating.
 *
 * WHY TWO LADDERS, and why this one exists at all. Rating goes DOWN. That
 * is what makes it meaningful and also what makes it punishing - a player
 * on a five-match losing streak watches the only number that represents
 * them fall, which is exactly when people stop opening an app. Career
 * points only ever rise, so there is always something moving in the right
 * direction.
 *
 *   rank title   = how good you are RIGHT NOW      (skill, can be lost)
 *   career title = everything you have EVER DONE   (mileage, permanent)
 *
 * THIS IS DELIBERATELY NOT COSMETICS. The developer rejected a cosmetic
 * store outright - "people aren't coming here to make cool profiles and
 * have fun skins" - and named the real motivations as comedy skill, status
 * and prizes. A permanent public record of showing up is status, earned by
 * doing the thing the app needs most: playing and judging.
 *
 * The titles are about MILEAGE, never quality, and are named so they
 * cannot be mistaken for the skill ranks. Someone can be a Walk-In with a
 * Headliner rating (naturally gifted, rarely plays) or an Institution
 * sitting at Average Joe (relentless, still working on it), and both of
 * those read as true rather than contradictory.
 */

/**
 * PLACEHOLDER THRESHOLDS, in the same sense as the rank thresholds and the
 * clip price: the ratios were chosen to feel right, the absolute numbers
 * want real playtesting.
 *
 * Calibrated against the default earn rates (10 a match, 25 a win, 5 a
 * vote): the first title lands within a session or two so the track is
 * visibly alive early, and the last is a genuine long haul rather than
 * something reachable in a fortnight. Every step is roughly a doubling,
 * which keeps each one feeling like a real jump instead of a grind tick.
 */
const CAREER_TITLES = [
  {threshold: 0, title: "Walk-In"},
  {threshold: 250, title: "Two-Drink Minimum"},
  {threshold: 750, title: "Road Dog"},
  {threshold: 1500, title: "Late Set"},
  {threshold: 3000, title: "Every Night"},
  {threshold: 6000, title: "Lifer"},
  {threshold: 12000, title: "Institution"},
];

/**
 * Where a player stands on the career track.
 *
 * Pure, so the whole ladder is testable without Firestore.
 *
 * Reads the CAREER total (`points`), never the spendable balance: buying a
 * clip must not demote anyone. That separation is the entire reason the
 * two numbers exist, and getting it wrong here would turn the permanent
 * ladder back into something that can go down.
 */
function careerStanding(user) {
  const points = Math.max(0, Number(user?.points) || 0);

  let index = 0;
  for (let i = 0; i < CAREER_TITLES.length; i++) {
    if (points >= CAREER_TITLES[i].threshold) index = i;
  }
  const current = CAREER_TITLES[index];
  const next = CAREER_TITLES[index + 1] ?? null;

  return {
    points,
    title: current.title,
    tier: index,
    nextTitle: next?.title ?? null,
    pointsToNext: next ? next.threshold - points : null,
    // 0..1 through the CURRENT band, so a progress bar fills evenly rather
    // than crawling across the widening later bands. Null at the top,
    // where there is nothing left to fill toward.
    progress: next ?
      (points - current.threshold) / (next.threshold - current.threshold) :
      null,
  };
}

module.exports = {careerStanding, CAREER_TITLES};
