import Link from "next/link";

export function SiteHeader() {
  return (
    <header className="site-header page-shell">
      <Link className="brand" href="/" aria-label="The Agora LA home">
        <span>The Agora</span>
        <span>LA</span>
      </Link>
      <nav className="site-nav" aria-label="Primary navigation">
        <Link href="/#how-it-works">How it works</Link>
        <Link href="/privacy">Privacy</Link>
        <Link href="/support">Support</Link>
      </nav>
    </header>
  );
}

export function SiteFooter() {
  return (
    <footer className="site-footer">
      <div className="footer-row page-shell">
        <p>The Agora LA. Listen with intent.</p>
        <nav className="footer-links" aria-label="Legal navigation">
          <Link href="/privacy">Privacy</Link>
          <Link href="/terms">Terms</Link>
          <Link href="/support">Support</Link>
        </nav>
      </div>
    </footer>
  );
}

export function LegalPage({
  eyebrow,
  title,
  updated,
  asideTitle,
  asideText,
  children,
}: {
  eyebrow: string;
  title: string;
  updated: string;
  asideTitle: string;
  asideText: string;
  children: React.ReactNode;
}) {
  return (
    <main>
      <SiteHeader />
      <header className="legal-hero page-shell">
        <p className="eyebrow">{eyebrow}</p>
        <h1>{title}</h1>
        <p>{updated}</p>
      </header>
      <div className="legal-layout page-shell">
        <aside className="legal-aside">
          <strong>{asideTitle}</strong>
          {asideText}
        </aside>
        <article className="prose">{children}</article>
      </div>
      <SiteFooter />
    </main>
  );
}
