"use client";

import { useEffect, useRef } from "react";

export default function OpenRouterCallbackPage() {
  const returnLink = useRef<HTMLAnchorElement>(null);

  useEffect(() => {
    const parameters = new URLSearchParams(window.location.search);
    const query = parameters.toString();
    const target = `theagorala://openrouter-auth${query ? `?${query}` : ""}`;
    returnLink.current?.setAttribute("href", target);
    window.location.replace(target);
  }, []);

  return (
    <main className="auth-return-shell">
      <section className="auth-return-card reveal" aria-live="polite">
        <div className="auth-return-mark" aria-hidden="true">
          A
        </div>
        <p className="eyebrow">Secure AI setup</p>
        <h1>Returning to The Agora</h1>
        <p>
          The Agora should reopen automatically to finish your AI connection.
        </p>
        <a ref={returnLink} className="button button-primary" href="theagorala://openrouter-auth">
          Return to The Agora
        </a>
        <p className="auth-return-note">
          If the app does not open, tap the button above. No credential is stored
          on this webpage.
        </p>
      </section>
    </main>
  );
}
