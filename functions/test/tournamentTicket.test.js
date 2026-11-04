/* Pure tests for the try-out ticket - gate, price, eligibility filter. */
const assert = require("assert");
const {
  resolveTicketGate, resolveTicketPrice, eligibleStandings,
  TICKET_PRICE_DEFAULT,
} = require("../tournamentTicket");

let passed = 0;
function ok(name, cond) {
  assert.ok(cond, name);
  passed += 1;
}

// --- resolveTicketGate: BOTH flags required, fail-safe to OFF ---
ok("gate needs both flags",
    resolveTicketGate({enabled: true, tryoutTicketEnabled: true}) === true);
ok("gate off when tournament off",
    resolveTicketGate({enabled: false, tryoutTicketEnabled: true}) === false);
ok("gate off when ticketing off",
    resolveTicketGate({enabled: true, tryoutTicketEnabled: false}) === false);
ok("gate off on empty config", resolveTicketGate(undefined) === false);
ok("gate off on garbled truthy",
    resolveTicketGate({enabled: 1, tryoutTicketEnabled: "yes"}) === false);

// --- resolveTicketPrice: bounds-checked, placeholder fallback ---
ok("price taken when valid",
    resolveTicketPrice({tryoutTicketPrice: 300}) === 300);
ok("price floored to int",
    resolveTicketPrice({tryoutTicketPrice: 150.9}) === 150);
ok("price falls back when absent",
    resolveTicketPrice({}) === TICKET_PRICE_DEFAULT);
ok("price falls back when zero/negative",
    resolveTicketPrice({tryoutTicketPrice: 0}) === TICKET_PRICE_DEFAULT &&
    resolveTicketPrice({tryoutTicketPrice: -5}) === TICKET_PRICE_DEFAULT);
ok("price falls back when non-numeric",
    resolveTicketPrice({tryoutTicketPrice: "lots"}) === TICKET_PRICE_DEFAULT);

// --- eligibleStandings: the gate bites only when ON ---
const standings = [
  {uid: "a", gain: 50}, {uid: "b", gain: 30},
  {uid: "c", gain: 20}, {uid: "d", gain: 10},
];
ok("gate OFF leaves standings untouched",
    eligibleStandings(standings, ["a"], false).length === 4);
ok("gate OFF ignores holders entirely",
    eligibleStandings(standings, [], false).length === 4);

const filtered = eligibleStandings(standings, ["a", "c"], true);
ok("gate ON keeps only holders",
    filtered.length === 2 && filtered[0].uid === "a" &&
    filtered[1].uid === "c");
ok("gate ON preserves rank order",
    eligibleStandings(standings, ["d", "b", "a"], true)
        .map((s) => s.uid).join(",") === "a,b,d");
ok("gate ON with no holders yields empty field",
    eligibleStandings(standings, [], true).length === 0);
ok("gate ON tolerates missing args",
    eligibleStandings(undefined, undefined, true).length === 0);
ok("a non-standings holder adds nothing",
    eligibleStandings(standings, ["a", "zzz"], true).length === 1);

console.log(`tournamentTicket: ${passed} checks passed`);
