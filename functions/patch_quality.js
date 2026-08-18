const fs = require("fs");

// --- matchmaking.js: accept and persist the report ------------------------
{
  const f = "matchmaking.js";
  let s = fs.readFileSync(f, "utf8");

  const a1 = '  const {matchId, outcome = "completed"} = data || {};';
  if (!s.includes(a1)) throw new Error("anchor 1 missing");
  s = s.replace(a1,
      '  const {matchId, outcome = "completed", quality} = data || {};');

  const a2 = "  // Claim the settle in a TRANSACTION, not a read-then-write.";
  if (!s.includes(a2)) throw new Error("anchor 2 missing");
  const insert = [
    "  // The caller's own capture-quality summary, recorded BEFORE the settle",
    "  // claim below and deliberately outside it. Both devices call this and",
    "  // only one wins the claim - so writing the report inside would keep",
    "  // whichever player raced faster and silently discard the other, who is",
    "  // quite often the one who actually had the problem.",
    "  //",
    "  // Keyed by uid because each player reports on their OWN camera and mic;",
    "  // there is no single number for a match. Never fatal: a bad report must",
    "  // not stop a battle being settled.",
    "  const cleanQuality = sanitiseQualityReport(quality);",
    "  if (cleanQuality) {",
    "    await matchRef.update({",
    "      [\"captureQuality.\" + auth.uid]: cleanQuality,",
    "    }).catch((e) => console.error(\"quality report failed:\", e.message));",
    "  }",
    "",
    a2,
  ].join("\n");
  s = s.replace(a2, insert);

  // Import next to the other local requires at the top of the file.
  const reqAnchor = 'const {HttpsError} = require("firebase-functions/v2/https");';
  if (!s.includes(reqAnchor)) throw new Error("require anchor missing");
  s = s.replace(reqAnchor, reqAnchor +
    '\nconst {sanitiseQualityReport} = require("./captureQuality");');

  fs.writeFileSync(f, s);
  console.log("matchmaking.js patched");
}

// --- autoRender.js: let it discount the caption ranking -------------------
{
  const f = "autoRender.js";
  let s = fs.readFileSync(f, "utf8");

  const a = "function captionScore(match, dayMedianVotes) {\n" +
    "  const votes = Number(match?.voteCount) || 0;\n" +
    "  const median = dayMedianVotes > 0 ? dayMedianVotes : 1;\n" +
    "  return (votes / median) * (1 + MARGIN_BOOST * voteMargin(match));\n" +
    "}";
  if (!s.includes(a)) throw new Error("captionScore anchor missing");

  const b = "function captionScore(match, dayMedianVotes) {\n" +
    "  const votes = Number(match?.voteCount) || 0;\n" +
    "  const median = dayMedianVotes > 0 ? dayMedianVotes : 1;\n" +
    "  return (votes / median) *\n" +
    "    (1 + MARGIN_BOOST * voteMargin(match)) *\n" +
    "    qualityFactor(match?.captureQuality);\n" +
    "}";
  s = s.replace(a, b);

  // Explain the new term where the score is documented.
  const docAnchor = " * THE HONEST LIMITATION: this measures how many people judged a clip,";
  if (!s.includes(docAnchor)) throw new Error("doc anchor missing");
  s = s.replace(docAnchor, [
    " * CAPTURE QUALITY DISCOUNTS THE WHOLE THING, because captions are the",
    " * expensive stage and a clip nobody can see or hear is the worst",
    " * possible thing to spend them on. It is a discount rather than a veto:",
    " * a dark clip with overwhelming votes may still be the best thing that",
    " * happened all week.",
    " *",
    docAnchor,
  ].join("\n"));

  const reqAnchor = 'const {getFirestore} = require("firebase-admin/firestore");';
  if (!s.includes(reqAnchor)) throw new Error("autoRender require anchor missing");
  s = s.replace(reqAnchor, reqAnchor +
    '\nconst {qualityFactor} = require("./captureQuality");');

  fs.writeFileSync(f, s);
  console.log("autoRender.js patched");
}
