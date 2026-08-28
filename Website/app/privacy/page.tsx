import type { Metadata } from "next";
import { LegalPage } from "../site-chrome";

export const metadata: Metadata = {
  title: "Privacy Policy",
  description: "How The Agora LA handles podcast and listener information.",
};

export default function PrivacyPage() {
  return (
    <LegalPage
      eyebrow="Your information"
      title="Privacy Policy"
      updated="Effective August 1, 2026"
      asideTitle="The short version"
      asideText="The Agora does not sell personal information, run advertising, or receive AI-provider credentials on an Agora server."
    >
      <h2>What this policy covers</h2>
      <p>
        This policy explains how The Agora LA (&quot;Agora,&quot; &quot;we,&quot;
        &quot;us,&quot; or &quot;our&quot;) handles information when you use The
        Agora LA iOS app.
      </p>

      <h2>Information we handle</h2>
      <ul>
        <li>
          Podcast information you submit, including links, episode audio,
          transcripts, titles, generated summaries and questions, and your
          written or spoken answers.
        </li>
        <li>
          An AI-provider credential created after you authorize a provider
          account. The credential is stored in the iPhone Keychain and is not
          sent to an Agora server.
        </li>
        <li>
          App preferences, saved episode material, generated questions,
          answers, and Agora Points stored locally on your device.
        </li>
      </ul>

      <h2>How we use information</h2>
      <p>
        The app uses this information to import and transcribe episodes, create
        episode-specific learning questions, evaluate your answers, and save
        your learning progress. We do not sell personal information, use it for
        cross-app tracking, or serve advertising.
      </p>

      <h2>AI and service providers</h2>
      <p>
        When you request an AI feature, the app sends the podcast material and
        listener answer needed for that feature directly to OpenRouter using
        the provider access you authorized. OpenRouter and any model provider it
        routes to process data under their own terms and privacy policies. Agora
        does not receive or store your provider credential on its servers.
      </p>
      <p>
        The Agora does not sell AI credits, collect payments, or receive a share
        of provider charges. You manage any AI-provider account and billing
        relationship separately from the app.
      </p>

      <h2>Retention and deletion</h2>
      <p>
        Saved episodes, transcripts, generated study material, answers, and
        Agora Points remain on your device until you replace them or delete the
        app and its data. Disconnecting your AI account removes the provider
        credential from the iPhone Keychain. The AI provider may retain
        information according to its own policy.
      </p>

      <h2>Security</h2>
      <p>
        The app uses encrypted network connections and the iPhone Keychain for
        provider access. No system can guarantee absolute security, but we work
        to limit access and collect only what the product needs.
      </p>

      <h2>Children</h2>
      <p>
        Agora is not directed to children under 13, and we do not knowingly
        collect personal information from children under 13. Podcast content is
        supplied by users and may not be appropriate for every age.
      </p>

      <h2 id="your-choices">Your choices</h2>
      <p>
        You can decline optional microphone and speech-recognition permissions,
        use typed answers instead, disconnect your AI provider, delete saved
        episode data, or delete the app. Provider-account privacy choices must
        be managed with that provider.
      </p>

      <h2>Contact and changes</h2>
      <p>
        For privacy questions or requests, email{" "}
        <a href="mailto:support@theagorala.com">support@theagorala.com</a>.
        We may update this policy as the service changes. The effective date
        above identifies the latest version.
      </p>
    </LegalPage>
  );
}
