import Link from "next/link";
import { SiteFooter, SiteHeader } from "./site-chrome";

export default function Home() {
  return (
    <main>
      <SiteHeader />

      <section className="hero page-shell">
        <div className="hero-copy reveal">
          <p className="eyebrow">Listen with intent</p>
          <h1>Turn every podcast into a practice field.</h1>
          <p className="hero-intro">
            The Agora LA transforms the podcasts you choose into focused recall
            sessions, grounded in what the episode actually said.
          </p>
          <div className="hero-actions">
            <a className="button button-primary" href="#how-it-works">
              See how it works
            </a>
            <Link className="button button-secondary" href="/support">
              Listener support
            </Link>
          </div>
        </div>

        <div className="lesson-card reveal reveal-delay">
          <div className="lesson-topline">
            <span>Agora check-in</span>
            <span className="live-pill">Transcript grounded</span>
          </div>
          <p className="lesson-question">
            What distinction does the speaker make between recognizing an idea
            and being able to recall it independently?
          </p>
          <div className="meter" aria-label="Example answer strength meter">
            <span />
          </div>
          <div className="lesson-score">
            <strong>89</strong>
            <span>Strong answer</span>
          </div>
          <p className="lesson-note">
            Feedback compares meaning, not exact wording, and points back to the
            podcast-supported answer.
          </p>
        </div>
      </section>

      <section id="how-it-works" className="section page-shell">
        <div className="section-heading">
          <p className="eyebrow">A better listening loop</p>
          <h2>Import. Understand. Recall.</h2>
        </div>
        <div className="feature-grid">
          <article className="feature-card">
            <span className="feature-number">01</span>
            <h3>Paste the podcast</h3>
            <p>
              Add an Apple Podcasts link, public RSS feed, or direct audio URL.
              The episode title, playable audio, and available details import
              immediately.
            </p>
          </article>
          <article className="feature-card">
            <span className="feature-number">02</span>
            <h3>Read the whole episode</h3>
            <p>
              The listener-authorized AI reads the complete transcript, writes
              a useful brief, and identifies the episode&apos;s strongest ideas.
            </p>
          </article>
          <article className="feature-card">
            <span className="feature-number">03</span>
            <h3>Practice what mattered</h3>
            <p>
              Answer episode-specific questions and receive feedback on what
              you understood, what you missed, and what the podcast supported.
            </p>
          </article>
        </div>
      </section>

      <section className="ownership-section">
        <div className="page-shell ownership-grid">
          <div>
            <p className="eyebrow eyebrow-light">Free by design</p>
            <h2>Your AI account. Your usage. No Agora bill.</h2>
          </div>
          <div className="ownership-copy">
            <p>
              The Agora does not sell credits, subscriptions, paid features, or
              AI access. Listeners authorize an AI provider account they control.
              If that provider charges for usage, the relationship is directly
              between the listener and the provider.
            </p>
            <p>
              Provider credentials stay in the iPhone Keychain. When cloud
              analysis is requested, an encrypted temporary copy powers that
              listener&apos;s job and is erased when it finishes. The Agora does not
              receive a payment share or operate an AI billing account.
            </p>
            <Link className="text-link light-link" href="/privacy">
              Read our privacy policy
            </Link>
          </div>
        </div>
      </section>

      <section className="section page-shell closing-section">
        <p className="eyebrow">Built for active listeners</p>
        <h2>Listening is the beginning. Retrieval makes it stick.</h2>
        <p>
          The iPhone app includes an original offline sample lesson so every
          listener can explore the complete learning flow without an account or
          purchase.
        </p>
        <Link className="button button-primary" href="/support">
          Explore listener support
        </Link>
      </section>

      <SiteFooter />
    </main>
  );
}
