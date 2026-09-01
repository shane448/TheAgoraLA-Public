# Agora Cloud Analysis

This service runs long podcast transcription and prompt generation outside the iPhone process. A submitted job continues when the listener backgrounds or closes the app.

## Privacy and billing

- Each request uses the listener's OpenRouter credential. The Agora does not provide or pay for AI usage.
- Credentials are encrypted with AES-256-GCM before entering PostgreSQL, decrypted only in worker memory, and erased when a job completes or fails.
- Completed and failed cloud-job records, including transcripts and generated study material, are automatically deleted after `JOB_RETENTION_DAYS` (seven days by default).
- The API never returns provider credentials and Fastify request-body logging is not enabled.
- Anonymous installation sessions avoid requiring an Agora account or Sign in with Apple.

## Deploy

1. Provision PostgreSQL and a container host that supports long-running workers, at least 2 GB RAM, persistent outbound HTTPS, and FFmpeg. Google Cloud Run with minimum instances, Railway, Render, or Fly.io are suitable; request-based serverless functions are not.
2. Copy `.env.example` into the host's secret manager. Generate independent values for `AGORA_SESSION_SECRET` and `PROVIDER_CREDENTIAL_ENCRYPTION_KEY`.
3. Deploy `Backend/Dockerfile`. Its startup command runs all ordered SQL migrations before starting the API and worker.
4. Confirm `GET /health` returns `{ "status": "ok" }` over HTTPS.
5. Set the iOS target build setting `AGORA_API_BASE_URL` to that HTTPS origin, for example `https://api.example.org`, then rebuild the app.

Generate secrets locally with `openssl rand -hex 32`. Do not place `.env`, database credentials, provider keys, or production secrets in source control.

## Verify

Run `npm run check`, then submit a test episode, close the iOS app after it reports that cloud analysis is running, and reopen the editor after the job completes. Verify that the transcript, summary, and prompts appear without resubmitting.
