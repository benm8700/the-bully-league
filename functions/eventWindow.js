/**
 * The daily prime-time window, server side.
 *
 * Shared by the push scheduler and by match qualification so there is one
 * definition of "is it happening right now" rather than two that can drift.
 */

const PACIFIC = "America/Los_Angeles";

/** Defaults mirror lib/core/services/event_window.dart. */
const DEFAULTS = {
  enabled: true,
  name: "Sixes and Sevens",
  startHourPacific: 18,
  endHourPacific: 19,
};

/**
 * How long after joining the queue a player can still be paired and keep
 * the window's benefits.
 *
 * This exists because matchmaking latency is not the player's fault. Queue
 * at 6:58, wait while the pool is thin, get paired at 7:02 - without this
 * you would lose the bonus for the app being slow, which is precisely the
 * kind of arbitrary penalty that makes a reward feel rigged.
 *
 * Bounded rather than open-ended so it cannot be farmed: today queue
 * entries are pruned at ten minutes anyway, but the planned standing-
 * challenge design lets entries live for hours, and without this cap a
 * challenge left at 6:59pm would still be minting bonuses at midnight.
 */
const PAIRING_GRACE_MS = 10 * 60 * 1000;

function readEventWindowConfig(data) {
  const out = {...DEFAULTS};
  if (!data) return out;
  if (typeof data.enabled === "boolean") out.enabled = data.enabled;
  if (typeof data.name === "string" && data.name.trim()) out.name = data.name.trim();

  // Bounds-checked per field for the same reason match settings are: this
  // document is hand-edited in the Firebase console with no validation in
  // between, and one bad value must not discard a good rest.
  const hour = (key) => {
    const v = data[key];
    return (typeof v === "number" && Number.isInteger(v) && v >= 0 && v <= 23) ? v : null;
  };
  const start = hour("startHourPacific");
  const end = hour("endHourPacific");
  if (start !== null) out.startHourPacific = start;
  if (end !== null && end > out.startHourPacific) out.endHourPacific = end;
  return out;
}

/**
 * Pacific wall-clock for an instant, via the real IANA database.
 *
 * The Flutter client reimplements the US daylight-saving rule in pure Dart
 * to avoid adding a dependency to a fragile Android toolchain. Node ships
 * full ICU, so there is no reason to hand-roll it here as well - that would
 * be two chances to get the same rule wrong.
 */
function pacificNow(date) {
  const parts = new Intl.DateTimeFormat("en-US", {
    timeZone: PACIFIC,
    year: "numeric", month: "2-digit", day: "2-digit",
    hour: "2-digit", minute: "2-digit", hour12: false,
  }).formatToParts(date);
  const get = (type) => Number(parts.find((p) => p.type === type).value);
  const hour = get("hour") % 24; // some ICU versions render midnight as 24
  return {
    dayKey: `${get("year")}-${String(get("month")).padStart(2, "0")}-` +
      `${String(get("day")).padStart(2, "0")}`,
    minutes: hour * 60 + get("minute"),
  };
}

/** Whether an instant falls inside the window. */
function isWithinWindow(date, config) {
  if (!config.enabled) return false;
  const {minutes} = pacificNow(date);
  return minutes >= config.startHourPacific * 60 &&
    minutes < config.endHourPacific * 60;
}

/**
 * Whether a match counts as a window match.
 *
 * THE RULE, decided explicitly: qualification is judged at the START of a
 * match, never at the end. A battle that kicks off at 6:58 and runs past
 * 7:00 qualifies in full. Anything else would penalise people for playing
 * a long match, or - worse - give them a reason to rush or abandon one to
 * beat the clock, which is the opposite of what an hour designed to get
 * people battling should encourage. There is deliberately no partial
 * credit and no proration.
 *
 * Queue-entry time counts too, within a bounded grace, so a slow pairing
 * during a thin pool doesn't cost someone the bonus.
 */
function qualifiesForWindow({pairedAtMs, queuedAtMs, config, now = pairedAtMs}) {
  if (!config.enabled) return false;
  if (!Number.isFinite(pairedAtMs)) return false;
  if (isWithinWindow(new Date(pairedAtMs), config)) return true;
  if (!Number.isFinite(queuedAtMs)) return false;
  // Only forgives pairing LATENCY, never a long-dormant queue entry.
  if (pairedAtMs - queuedAtMs > PAIRING_GRACE_MS) return false;
  if (pairedAtMs < queuedAtMs) return false;
  return isWithinWindow(new Date(queuedAtMs), config);
}

module.exports = {
  DEFAULTS,
  PACIFIC,
  PAIRING_GRACE_MS,
  readEventWindowConfig,
  pacificNow,
  isWithinWindow,
  qualifiesForWindow,
};
