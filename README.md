# The Agora LA

The Agora LA is a free SwiftUI podcast-learning app. A listener pastes an Apple Podcasts, RSS, or direct HTTPS audio URL; the app resolves the episode, prepares a brief and full transcript, selects the strongest episode-specific questions, and gives constructive feedback on the listener's answers.

## Free AI Architecture

- The Agora has no paid app features, subscriptions, in-app purchases, or Agora-issued credits.
- Listeners authorize an OpenRouter account through OAuth with PKCE. OpenRouter creates a user-controlled credential that is stored in the iPhone Keychain.
- AI requests use the provider authorized by the listener. Without a configured cloud endpoint they run directly on the device; production cloud jobs use the same listener-owned credential through an encrypted, short-lived queue.
- The app contains no link or call to action to buy provider credits. Listeners manage any provider relationship separately.
- No Agora account or Sign in with Apple is required.
- An original, offline sample lesson lets App Review and new listeners inspect the brief, transcript, question, scoring, feedback, and points without an external account.

OpenAI's API guidance says not to embed a developer API key in a mobile app. The app therefore uses OpenRouter's documented PKCE flow to obtain a user-controlled provider credential rather than shipping an Agora-owned secret.

## Prompt Quality Pipeline

The iOS app processes the complete transcript rather than a sample:

1. It annotates the full transcript with short, time-bounded episode positions.
2. The listener's provider identifies consequential, episode-specific claims and supplies verbatim transcript evidence.
3. The provider generates more candidates than requested and scores importance, specificity, answer alignment, and grounding.
4. Deterministic checks reject stock wording, fabricated evidence, weak question/evidence overlap, mismatched expected answers, and duplicate ideas.
5. Each prompt is scheduled after the end of its final supporting passage, with a listening buffer; missing or legacy zero timestamps are aligned locally before playback.
6. Only the strongest verified candidates become listener-facing prompts.

## Open and Run

Open `TheAgoraLA.xcodeproj`, select the `TheAgoraLA` scheme and an iPhone simulator, then press Run. No local backend is required because the app retains a direct-processing fallback.

For release, deploy the service documented in `Backend/README.md` and set the target's `AGORA_API_BASE_URL` build setting to its HTTPS origin. Long analyses then continue in the cloud after the listener leaves the app and are restored when the editor reopens.

Open **AI Setup** and follow the three guided steps for live podcast analysis: automatic secure provider sign-in, analysis quality, and readiness confirmation. Listeners who already created an OpenRouter key can paste and verify it directly in step one. Choose **Explore a Sample Lesson** to test the core experience without an account.

## Apple Setup

- Enroll the officially recognized nonprofit as an organization and request Apple's fee waiver during enrollment.
- Assign the target to that organization team and confirm ownership of `com.theagora.la`.
- Do not enable In-App Purchase or Sign in with Apple for version 1.0.
- Do not sign the Paid Applications Agreement for this app.
- Complete the free-app metadata, privacy labels, age rating, screenshots, content-rights answers, and review notes in `AppStore/`.

## Website and Legal Pages

The public Privacy Policy, Terms, and Support site is deployed at `https://the-agora-la-app.shareid.chatgpt.site`. Its maintained source is in `Website/`; `Backend/public/` is retained only as the original legal draft. Activate `support@theagorala.com` and obtain legal review before submission. The cloud worker in `Backend/` is designed for listener-funded processing and does not use an Agora-owned AI key.

## Verification

```sh
xcodebuild -project TheAgoraLA.xcodeproj -scheme TheAgoraLA \
  -configuration Release -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /private/tmp/TheAgoraLA-DerivedData \
  CODE_SIGNING_ALLOWED=NO build
```

Before submission, test provider authorization and disconnect, podcast imports, long transcripts, answer feedback, offline review mode, privacy links, and the final signed TestFlight build on a physical iPhone.
