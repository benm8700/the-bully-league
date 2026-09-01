/**
 * "Get the app" - the website's one job for an arriving visitor.
 *
 * WHY THE SITE STOPPED OFFERING VOTING. The vote page required sign-in,
 * and accounts can only be created in the app - so the person this site
 * exists for, the one who clicked a shared clip, could not vote no matter
 * how much they wanted to. Anyone who *could* vote already had the app,
 * where the Judge feed is better. It was a prominent path almost nobody
 * could use, sitting where the download call-to-action should be.
 *
 * So the site is a shop window: watch the clip, then get the app.
 *
 * THE LINK IS AN ENV VAR ON PURPOSE. There is no Play listing yet, and a
 * button that goes nowhere in front of real traffic is worse than no
 * button. Until NEXT_PUBLIC_APP_STORE_URL is set this renders as an
 * honest "coming soon" rather than a dead link - so the button is built
 * now and activating it is one Vercel setting rather than a code change
 * and a deploy.
 */
export function StoreCta({
  variant = "block",
}: {
  variant?: "block" | "inline";
}) {
  const url = process.env.NEXT_PUBLIC_APP_STORE_URL;
  const live = Boolean(url);

  const base =
    "inline-flex items-center justify-center gap-2 rounded-full font-semibold transition-all";
  const size =
    variant === "inline" ? "px-4 py-2 text-sm" : "px-6 py-3 text-base";

  if (!live) {
    return (
      <span
        className={`${base} ${size} bg-surface-2 text-muted cursor-default border border-outline`}
        aria-disabled="true"
      >
        <AndroidGlyph />
        Coming soon to Android
      </span>
    );
  }

  return (
    <a
      href={url}
      className={`${base} ${size} text-white hover:opacity-90`}
      style={{ background: "var(--primary)", boxShadow: "0 8px 24px rgba(234,76,109,0.35)" }}
    >
      <AndroidGlyph />
      Get The Bully League
    </a>
  );
}

function AndroidGlyph() {
  return (
    <svg width="16" height="16" viewBox="0 0 24 24" fill="currentColor" aria-hidden>
      <path d="M6 9h12v8a2 2 0 0 1-2 2h-1v2.5a1.5 1.5 0 0 1-3 0V19h-2v2.5a1.5 1.5 0 0 1-3 0V19H8a2 2 0 0 1-2-2V9Zm-2 0a1.5 1.5 0 0 1 3 0v6a1.5 1.5 0 0 1-3 0V9Zm13 0a1.5 1.5 0 0 1 3 0v6a1.5 1.5 0 0 1-3 0V9ZM8 8a4 4 0 0 1 8 0H8Zm2-3.2-.9-1.4.8-.5.9 1.5a5 5 0 0 1 2.4 0l.9-1.5.8.5-.9 1.4A4 4 0 0 1 8 8" />
    </svg>
  );
}
