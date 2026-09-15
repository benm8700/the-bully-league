# Home hero art

Developer-provided background images for the Home screen heroes.

- `tournament_hero.png` — 1080×1350 (4:5). Cinematic gold/black arena, crown,
  crowd. Main subject in the top ~60%; bottom ~40% darker/simple (Flutter lays a
  scrim + all text/buttons over it).
- `roast_hero.png` — 1080×810 (4:3). Illustrated red-vs-blue opponents + mics.
  Subject in the top ~65%; bottom ~35% darker/simple.

Both are PURE BACKGROUND ART — no text is baked in. Every dynamic element
(TOURNAMENT, 8 ROASTERS. 1 CHAMPION., Real Prizes, Live Bracket, countdown/LIVE,
ENTER TOURNAMENT, ROAST A STRANGER, RANDOM OPPONENT. REAL ROASTS., FIND A MATCH)
is a Flutter overlay. Until the PNGs are added, the heroes render a plain dark
placeholder so the app still builds and lays out correctly.
