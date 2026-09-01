# AI Provider Contract

Version 1.0 uses an Agora-operated cloud job service for long-running episode transcription and analysis. It does not use StoreKit, subscriptions, paid features, or Agora-issued AI credits. The listener authorizes an AI provider account and any provider charges remain directly between that listener and the provider.

## Account Connection

The app uses OpenRouter OAuth with PKCE:

1. Generate a random verifier on device and derive its SHA-256 challenge.
2. Open `https://openrouter.ai/auth` in `ASWebAuthenticationSession` with the public HTTPS callback in `AppLinks.openRouterCallback`. That page immediately returns the authorization result to `theagorala://openrouter-auth`.
3. Exchange the returned authorization code at `https://openrouter.ai/api/v1/auth/keys` using the original verifier.
4. Store the resulting provider key in the iPhone Keychain with `ThisDeviceOnly` protection.
5. Delete the Keychain item immediately when the listener disconnects.

For listeners who already have an OpenRouter key, the app also offers a clearly labeled manual paste-and-verify path. Whether created through authorization or pasted manually, the key is stored in the iPhone Keychain. For cloud analysis, an encrypted temporary copy is sent to the Agora job service, decrypted only in worker memory, and erased from the job when it completes or fails.

## Provider Requests

- Chat and structured analysis: `POST https://openrouter.ai/api/v1/chat/completions`
- Audio transcription: `POST https://openrouter.ai/api/v1/audio/transcriptions`
- Authentication: `Authorization: Bearer <listener-owned-provider-key>`
- Attribution: the public app website URL in `AppLinks.home` and `X-OpenRouter-Title: The Agora LA`

Podcast audio or transcripts used for long episode analysis travel through the Agora cloud job service to the authorized provider. Completed job records are retained for no more than seven days so an interrupted app session can recover its result. Listener answers are graded directly from the app through the authorized provider and are not stored by the Agora cloud service.

## Episode Analysis

The app imports public metadata without AI. Apple Podcasts show links resolve through Apple's lookup service to the publisher's RSS feed. Public RSS transcript tags are preferred; otherwise audio transcription uses the connected provider.

AI analysis must read the complete transcript and return:

- A listener-facing episode brief grounded only in the transcript.
- Episode-specific questions focused on important claims, mechanisms, distinctions, examples, and conclusions.
- An expected answer that directly answers its paired question using only podcast-supported information.
- Exact transcript evidence and an approximate episode timestamp for every candidate.
- Quality scores for importance, specificity, answer alignment, and grounding.

Candidates that are generic, duplicative, opinion-based, weakly grounded, or poorly aligned are rejected locally before the best questions are saved.

## Answer Evaluation

The provider grades semantic meaning rather than exact wording, credits correct paraphrases, identifies the most important missing detail, and must not introduce facts beyond the podcast-supported answer. If the provider is unavailable, the app uses a conservative offline estimate and labels it clearly.

## Failure Handling

- `401` or `403`: ask the listener to reconnect the provider account.
- `402`: tell the listener that their provider account needs available credits.
- Cancellation: return to the app without displaying an error.
- Invalid structured output: show a retryable error and do not save partial prompts.
- Missing provider connection: retain imported episode metadata and direct the listener to connect AI for transcript analysis.

## App Review

The built-in sample lesson is original content and requires no account, provider, purchase, or network service. It demonstrates the episode brief, full transcript, prompt, answer entry, scoring feedback, supported answer, and Agora Points flow.

The production service under `Backend/` must be deployed with PostgreSQL, FFmpeg, TLS, encrypted provider-credential storage, and seven-day job retention. The iOS target's `AGORA_API_BASE_URL` must point to that production origin.
