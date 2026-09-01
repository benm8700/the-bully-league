import Link from "next/link";

export function SiteFooter() {
  return (
    <footer className="border-t border-outline-soft px-6 py-10">
      <div className="mx-auto flex max-w-6xl flex-col items-center gap-4 text-center sm:flex-row sm:justify-between sm:text-left">
        <div>
          <div className="display text-base">The Bully League</div>
          <p className="mt-1 text-xs text-muted">
            Live 1-on-1 roast battles. Judged by the crowd. 18+.
          </p>
        </div>
        <nav className="flex items-center gap-5 text-xs text-muted">
          <Link href="/demo" className="transition-colors hover:text-foreground">
            Demo
          </Link>
          <Link href="/matches" className="transition-colors hover:text-foreground">
            Matches
          </Link>
          <Link href="/legal" className="transition-colors hover:text-foreground">
            Terms &amp; Privacy
          </Link>
        </nav>
      </div>
    </footer>
  );
}
