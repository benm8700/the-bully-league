const fs = require("fs");

function edit(file, edits, addImport) {
  let s = fs.readFileSync(file, "utf8");
  const eol = s.includes("\r\n") ? "\r\n" : "\n";
  const fix = (t) => t.split("\n").join(eol);
  for (const [from, to, label] of edits) {
    const a = fix(from);
    if (!s.includes(a)) throw new Error(`${file}: ${label} not found`);
    s = s.split(a).join(fix(to));
  }
  if (addImport && !s.includes("theme/app_theme.dart")) {
    s = s.replace("import 'package:flutter/material.dart';",
        "import 'package:flutter/material.dart';\n\n" +
        "import '" + addImport + "';");
  }
  // Drop the now-unused house_theme import if present and unused.
  if (!s.includes("House.")) {
    s = s.replace(/import '(\.\.\/)*theme\/house_theme\.dart';\r?\n/, "");
  }
  fs.writeFileSync(file, s);
  console.log(`${file} patched`);
}

// --- laugh_meter.dart: gauge + title colour from the palette -------------
edit("lib/widgets/laugh_meter.dart", [
  [
    "            color: isGoat ? House.brass : null,",
    "            color: isGoat ? context.palette.accent : null,",
    "goat title",
  ],
  [
    "                color: House.house,",
    "                color: Theme.of(context).colorScheme.surface,",
    "track bg",
  ],
  [
    "                    gradient: LinearGradient(\n" +
    "                      colors: [\n" +
    "                        House.brass.withValues(alpha: 0.55),\n" +
    "                        House.brass,\n" +
    "                        House.spot,\n" +
    "                      ],\n" +
    "                      stops: const [0.0, 0.6, 1.0],\n" +
    "                    ),",
    "                    gradient: LinearGradient(\n" +
    "                      colors: [\n" +
    "                        context.palette.gaugeFrom,\n" +
    "                        context.palette.gaugeTo,\n" +
    "                        context.palette.gaugeTo,\n" +
    "                      ],\n" +
    "                      stops: const [0.0, 0.75, 1.0],\n" +
    "                    ),",
    "gauge gradient",
  ],
  [
    "                              color: House.brass.withValues(alpha: 0.55),",
    "                              color: context.palette.accent"
      + ".withValues(alpha: 0.55),",
    "glow",
  ],
], "../theme/app_theme.dart");

// --- live_tally.dart: the two gels from the palette ----------------------
edit("lib/widgets/live_tally.dart", [
  [
    "                    child: Container(height: 10, color: House.gelRed),",
    "                    child: Container(height: 10, color: context.palette.gelA),",
    "gelA",
  ],
  [
    "                    child: Container(height: 10, color: House.gelBlue),",
    "                    child: Container(height: 10, color: context.palette.gelB),",
    "gelB",
  ],
], "../theme/app_theme.dart");

// --- match_screen.dart: error uses the scheme ----------------------------
edit("lib/screens/match/match_screen.dart", [
  [
    "              Text(_matchSaveError!, style: const TextStyle(color: House.alarm))",
    "              Text(_matchSaveError!,\n" +
    "                  style: TextStyle(\n" +
    "                      color: Theme.of(context).colorScheme.error))",
    "match error",
  ],
], "../../theme/app_theme.dart");

// --- pre_match_screen.dart: mic meter uses accent/outline ----------------
edit("lib/screens/match/pre_match_screen.dart", [
  [
    "              color: _micVerified ? House.brass : House.smoke,",
    "              color: _micVerified\n" +
    "                  ? context.palette.accent\n" +
    "                  : Theme.of(context).colorScheme.outline,",
    "mic icon",
  ],
  [
    "                  color: _micVerified ? House.brass : House.smoke,",
    "                  color: _micVerified\n" +
    "                      ? context.palette.accent\n" +
    "                      : Theme.of(context).colorScheme.outline,",
    "mic bar",
  ],
], "../../theme/app_theme.dart");
