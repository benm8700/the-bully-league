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
    "inline-flex items-center justify-center gap-2 rounded-full font-medium transition-colors";
  const size =
    variant === "inline" ? "px-4 py-2 text-sm" : "px-6 py-3 text-base";

  if (!live) {
    return (
      <div className="flex flex-col items-center gap-2">
        <span
          className={`${base} ${size} bg-foreground/10 text-foreground/50 cursor-default`}
          aria-disabled="true"
        >
          Coming soon to Android
        </span>
        {variant === "block" && (
          <span className="text-xs text-foreground/50">
            Battles happen in the app.
          </span>
        )}
      </div>
    );
  }

  return (
    <div className="flex flex-col items-center gap-2">
      <a
        href={url}
        className={`${base} ${size} bg-accent text-background hover:opacity-90`}
      >
        Get The Bully League
      </a>
      {variant === "block" && (
        <span className="text-xs text-foreground/50">
          Free to watch and judge. Battles happen in the app.
        </span>
      )}
    </div>
  );
}
