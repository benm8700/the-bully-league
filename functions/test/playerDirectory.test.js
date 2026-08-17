const assert = require("assert");
const {
  isVisibleTo, publicCard, normaliseName,
} = require("../playerDirectory");

let passed = 0;
function check(name, fn) {
  fn();
  passed++;
  console.log(`  ok - ${name}`);
}

const ME = "me";
const THEM = "them";
const viewer = (over = {}) => ({blockedUserIds: [], ...over});
const candidate = (over = {}) => ({
  username: "Someone", accountStatus: "active", blockedUserIds: [], ...over,
});

console.log("playerDirectory");

check("an ordinary player is visible", () => {
  assert.strictEqual(
      isVisibleTo(candidate(), viewer(), ME, THEM), true);
});

check("OPTING OUT IS ABSOLUTE", () => {
  // Anyone can remove themselves from a searchable list of names and
  // faces, with no justification required.
  assert.strictEqual(
      isVisibleTo(candidate({directoryListed: false}), viewer(), ME, THEM),
      false);
});

check("only an explicit false hides someone", () => {
  // Every existing account has no such field, and treating absent as
  // opted-out would leave the directory permanently empty - the same
  // missing-field trap as accountStatus and createdAt.
  for (const value of [undefined, null, true]) {
    assert.strictEqual(
        isVisibleTo(candidate({directoryListed: value}), viewer(), ME, THEM),
        true, `directoryListed=${value}`);
  }
});

check("A BLOCK HIDES IN BOTH DIRECTIONS", () => {
  // Hiding only the blocked party would leave the person who blocked
  // still findable - precisely backwards, since they are the one who
  // asked not to be contacted.
  assert.strictEqual(
      isVisibleTo(candidate(), viewer({blockedUserIds: [THEM]}), ME, THEM),
      false, "someone I blocked must not appear");
  assert.strictEqual(
      isVisibleTo(candidate({blockedUserIds: [ME]}), viewer(), ME, THEM),
      false, "someone who blocked me must not appear");
});

check("a banned account is never listed", () => {
  assert.strictEqual(
      isVisibleTo(candidate({accountStatus: "banned"}), viewer(), ME, THEM),
      false);
});

check("a legacy account with no status is still listed", () => {
  const legacy = {username: "Old"};
  assert.strictEqual(isVisibleTo(legacy, viewer(), ME, THEM), true);
});

check("you never find yourself", () => {
  assert.strictEqual(isVisibleTo(candidate(), viewer(), ME, ME), false);
});

check("a missing candidate is not visible rather than throwing", () => {
  assert.strictEqual(isVisibleTo(null, viewer(), ME, THEM), false);
});

// --------------------------------------------------- what is exposed
check("THE CARD CARRIES A NAME, A FACE AND A RANK - NOTHING ELSE", () => {
  // The profile exists to give an OPPONENT ammo during a match. Hometown,
  // job and the volunteered ammo text are fine for someone you were just
  // paired with and wrong for a stranger who came looking for you.
  const card = publicCard(THEM, {
    username: "Someone",
    rankTitle: "Regular",
    rating: 1450,
    profile: {
      photoUrls: ["face.jpg", "second.jpg", "third.jpg"],
      hometown: "San Diego",
      profession: "Dentist",
      ammoText: "I still live with my mum",
      education: "State",
    },
  });
  assert.deepStrictEqual(Object.keys(card).sort(),
      ["photoUrl", "rankTitle", "uid", "username"]);
  const serialised = JSON.stringify(card);
  for (const leak of ["San Diego", "Dentist", "mum", "State", "1450"]) {
    assert.ok(!serialised.includes(leak), `leaked: ${leak}`);
  }
});

check("only the FIRST photo is exposed, not the gallery", () => {
  const card = publicCard(THEM, {
    username: "Someone",
    profile: {photoUrls: ["face.jpg", "second.jpg"]},
  });
  assert.strictEqual(card.photoUrl, "face.jpg");
  assert.ok(!JSON.stringify(card).includes("second.jpg"));
});

check("a player with no photos still produces a usable card", () => {
  const card = publicCard(THEM, {username: "Someone"});
  assert.strictEqual(card.photoUrl, null);
  assert.strictEqual(card.username, "Someone");
});

// ------------------------------------------------------- name matching
check("names normalise for case-insensitive matching", () => {
  assert.strictEqual(normaliseName("  RoastKing  "), "roastking");
  assert.strictEqual(normaliseName(null), "");
  assert.strictEqual(normaliseName(42), "");
});

console.log(`\n${passed} checks passed.`);
