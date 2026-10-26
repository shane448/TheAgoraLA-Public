# Agora Mind: design process

**Date:** October 25, 2026
**Branch:** `shane/agora-lite`
**Status:** Agreed with Shane on October 25, 2026. Nothing in this plan has been built yet.

Agora Mind is the current app, renamed, with AI that The Agora LA pays for. A listener pastes a podcast link and gets questions without creating or connecting an AI account. This document is the process for designing and building it: the choices it rests on, who reviews what, and the steps in order.

It builds on the Agora Lite plan in [`gcp-small-scale-testing.md`](gcp-small-scale-testing.md), which already describes the Google Cloud server and a project-paid key (option B in its section 4.1). Agora Mind is that server, plus spending limits and abuse protection, plus an app that no longer asks for an AI account.

---

## Choices this process is built on

| Question | Choice | Why |
|---|---|---|
| Separate app or the current one? | Rename the current app to Agora Mind. Keep "use your own OpenRouter account" as an advanced setting. | Apple can reject near-duplicate apps (guideline 4.3), and one app is half the upkeep. The own-account option lets heavy listeners keep going when the monthly budget runs out, and the server already accepts listener keys. |
| Starting AI budget | A hard cap of $100 a month on small models. The board sets the ongoing budget after real costs are measured. | Claude Haiku 5.5 plus open-source transcription costs an estimated 5–6¢ per hour-long episode, so $100 covers roughly 1,500–2,000 episodes. Today's default model (gpt-5.6-terra) would cover about 150. |
| Who reviews | The research collaborator reviews the technical design and code. TestFlight listeners review question quality and ease of use. The board or finance lead reviews the budget and limits, once. | Each reviewer looks at what they know best, at one checkpoint, so reviews don't slow every step. |
| Pace | A short written design for the decisions that are expensive to change, then small steps that each end with something Shane can try. | Most of the research is done. The remaining questions are answered faster by testing than by writing. |
| Abuse protection | No accounts. Apple App Attest proves a request comes from the real app; DeviceCheck lets limits survive reinstalling. | Keeps the app account-free while stopping scripts and reinstall loops from spending the nonprofit's money. |

## What stays true

- The nonprofit's AI key lives only in Google Secret Manager on the server. It is never in the app, the repository, logs, or chat. The `CLAUDE.md` rule against an Agora-owned key in the app or repository still holds.
- Spending has hard stops, not just alerts: a credit limit on the OpenRouter key, a per-device allowance on the server, and a switch that pauses built-in AI.
- The one-button Import, Analyze & Save flow, transcript-grounded questions, and the rule that prompts play after their evidence don't change.
- Listeners still give permission before episode text goes to AI. What changes is who pays, not whether they're asked.
- iOS 16 support stays.
- This repository is public. Budget memos and anything about donors stay out of it.

---

## Who reviews what

Shane approves every step and makes the final call at each checkpoint.

| Checkpoint | When | Reviewer | They get | They decide |
|---|---|---|---|---|
| A. Design review | End of stage 0 | Research collaborator | The design brief | Whether the server, spending, and abuse design is sound |
| B. Code review | End of step 4, before any outside tester | Research collaborator | The branch's changes since stage 0 | Whether it's safe to hand to listeners |
| C. Listener round | Step 5 | 10–20 TestFlight listeners | Agora Mind on TestFlight for two weeks | Whether the questions are good and setup feels effortless |
| D. Budget sign-off | After step 5, before public release | Board or finance lead | A one-page budget memo with measured costs | The monthly budget, the per-device allowance, and what happens when the budget runs out |

---

## The steps

Estimates assume someone familiar with the codebase. Each step after stage 0 ends with a **Try it** that Shane can do on a phone or read directly.

### Stage 0: Design brief (1–2 days)

Write `docs/research/agora-mind-design.md`, two pages at most, covering only the decisions that are expensive to change later:

1. **Spending controls.** The OpenRouter key's credit limit; Google Cloud budget alerts at 50, 90, and 100%; a per-device monthly allowance (proposed for testing: 20 episodes per device per month, with grading at the existing 60 answers a day, `DAILY_SCORE_LIMIT` in `Backend/src/config.ts`); and a pause switch that turns built-in AI off and points listeners to the own-account option.
2. **Abuse protection.** Native App Attest, which keeps the app free of third-party packages, or Firebase App Check, which needs less server code but adds the Firebase SDK. Recommended: native. Use DeviceCheck's two per-device bits to mark a device that already used this month's allowance, so reinstalling doesn't reset it.
3. **Where the allowance lives.** Reuse the anonymous device sessions (`POST /v1/auth/device`) and the `credit_ledger` table left from in-app purchases: grant each device a monthly allowance and charge one credit per new episode analysis.
4. **Shared episode results.** When two listeners import the same public episode, reuse the first analysis instead of paying twice. Today's dedupe is per listener (`Backend/src/app.ts:277–287`). Public podcast content isn't personal data, but the privacy policy promises deletion of job records within 7 days, so this needs a policy decision.
5. **When money runs out.** What a listener sees when their allowance or the monthly budget is used up.
6. **Privacy changes.** What goes to OpenRouter under the nonprofit's account, what is stored and for how long, and the text changes needed in the privacy policy, support page, App Store privacy labels, metadata, and review notes.
7. **Name check.** Confirm "Agora Mind" is available as an App Store name and run a basic trademark search.

**Done when:** Shane and the research collaborator approve the brief (checkpoint A).

### Step 1: Can a small model write good questions? (1–2 days)

Handoff steps 2 and 4. Compare transcription with `openai/whisper-large-v3` and `qwen/qwen3-asr-1.7b`, and run the curation harness with Claude Haiku 5.5 and gpt-6-luna against gpt-5.6-terra, on three episodes Shane knows well.

**Try it:** read each model's questions for those episodes side by side.
**Done when:** one transcription model and one question-writing model are chosen, with measured cost per episode, and recorded in a dated findings file.

### Step 2: The server does all the AI on the nonprofit's key (2–3 days)

Handoff steps 3, 5, and 6. Allow non-Whisper speech models, split the API from the per-episode job, and deploy the Agora Lite sandbox on Google Cloud with the nonprofit's key in Secret Manager, a credit limit on the key, and budget alerts. Move answer grading to the server on the same key: today the phone grades with the listener's key (`score` in `Sources/OpenRouterClient.swift`), and the server's grading model defaults to gpt-5.6-terra (`OPENAI_SCORING_MODEL` in `Backend/src/config.ts`), which should become the model chosen in step 1.

Update the product rule in `CLAUDE.md` and `AGENTS.md` in this step, from "Listeners use their own OpenRouter account" to built-in AI with the key held only in Secret Manager.

**Try it:** a test build pointed at the sandbox imports an episode and grades a spoken answer with no AI sign-in.
**Done when:** three real episodes produce timed questions, and `npm run check` and the iOS build pass.

### Step 3: Limits and abuse protection (2–3 days)

Build what the brief decided: App Attest, DeviceCheck, the monthly allowance, the pause switch, and shared episode results if approved.

**Try it:** use up a small test allowance on the phone and see the limit message and the own-account option; flip the pause switch and see built-in AI turn off.
**Done when:** those behaviors work, a request without a valid App Attest assertion is rejected, and backend tests cover all three.

### Step 4: The app becomes Agora Mind (2–3 days)

- Change the display name to Agora Mind. Keep the bundle ID so existing installs update in place.
- First run becomes paste a link, give permission, analyze. Today `AIProcessingConsent.nextStep` (`Sources/Models.swift:22`) sends listeners without a connected account to `.connectAccount`.
- Move "Use your own OpenRouter account" to an advanced setting, offered when the allowance runs out.
- Built-in AI runs only on the server. The on-phone pipeline remains only for own-account listeners until it's retired (handoff decision 4).
- Update the privacy policy and support page (`Website/app/privacy`, `Website/app/support`), App Store metadata (`AppStore/metadata.md` currently says "Agora does not include an AI allowance"), review notes (App Review no longer needs an OpenRouter key from us), and privacy labels.

**Try it:** delete the app, install it fresh, paste a link, get questions, and answer one by voice, without ever seeing an AI sign-in.
**Done when:** that works on a real iPhone, every check in `CLAUDE.md` passes, and the research collaborator has reviewed the changes (checkpoint B).

### Step 5: Listener round on TestFlight (2 weeks)

Invite 10–20 listeners. External TestFlight goes through Apple's beta review, which checks the privacy policy, so step 4's text changes must land first. Measure:

- real cost per episode and per listener (OpenRouter activity and Google billing);
- failed analyses and their causes;
- question quality, through a short survey (were the questions about what mattered; too easy or too hard);
- who hit their allowance, and any signs of abuse.

**Done when:** results are written up in a dated findings file and the one-page budget memo is drafted for checkpoint D. The memo uses totals only and stays out of this repository.

### Checkpoint D: Budget sign-off

The board or finance lead approves the monthly budget, the public per-device allowance, and what happens when the budget is used up.

### Step 6: Release (1 day, plus App Review)

When Shane says "merge it": open the pull request into `main`, remove the research notices from `CLAUDE.md` and `AGENTS.md`, run every check, and merge after Shane approves. Submit Agora Mind to the App Store. For the first month, compare spending against the cap every week.

---

## How each step runs

1. Claude proposes the step's plan in a few lines; Shane approves or redirects.
2. Work happens on `shane/agora-lite` and is pushed with `git push claude HEAD:shane/agora-lite`.
3. The checks in `CLAUDE.md` run before every commit of code.
4. The step ends with its **Try it**. Shane decides: next step, adjust, or stop.
5. What was learned goes into a dated findings file, and `README.md` and `HANDOFF.md` are kept current.
6. The research collaborator gets a short note after each step, so they can follow without becoming a blocker.

## Spending during the process

| Phase | Cap on the nonprofit's OpenRouter key |
|---|---|
| Steps 1–4 (Shane testing alone) | $25 in total |
| Step 5 (listener round) | $100 |
| After launch | Set at checkpoint D |

Google Cloud itself costs about $10–15 a month at this scale, mostly the database (see `gcp-small-scale-testing.md` section 7).

## Timeline (estimate)

| Phase | Working days |
|---|---|
| Stage 0 to step 4 | 8–13 |
| Step 5 listener round | 10 (two calendar weeks) |
| Checkpoint D and release | Depends on the board's schedule, plus 1–2 days of App Review |

Roughly 5–7 weeks from start to the App Store.
