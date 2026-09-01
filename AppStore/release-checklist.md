# Release Checklist

## Nonprofit Enrollment

- Confirm the organization is an officially recognized nonprofit legal entity.
- Confirm the applicant has authority to bind the organization.
- Confirm the exact legal name, D-U-N-S number, physical address, public website, organization-domain email, and phone match official records.
- Withdraw the pending individual enrollment only after those records are ready, then restart as an organization and request the fee waiver during enrollment.
- Do not sign Apple's Paid Applications Agreement. Version 1.0 is free and has no in-app purchases or sales of digital goods by The Agora.

## Website and Support

- Confirm `/privacy`, `/terms`, and `/support` remain public at `https://the-agora-la-app.shareid.chatgpt.site` with valid TLS.
- Make `support@theagorala.com` operational and monitored.
- Have a qualified attorney review the initial Privacy Policy and Terms.

## App Store Connect

- Create the App ID `com.theagora.la` without In-App Purchase or Sign in with Apple capabilities.
- Create the app record and select the nonprofit organization team in Xcode.
- Set price to Free and do not create in-app purchase products.
- Complete the metadata, privacy questionnaire, age rating, content-rights questions, and review notes from this folder.
- Upload polished iPhone and iPad screenshots with no transparency.
- Use manual release for version 1.0.

## Production Verification

- Test OpenRouter authorization, cancellation, disconnect, expired access, insufficient provider balance, and network failures on a physical iPhone.
- Confirm the Release build contains no StoreKit product identifiers, Agora payment flow, managed-service URL, or Sign in with Apple entitlement.
- Test the offline sample lesson, full transcript, answer scoring, feedback, and Agora Points without an AI account.
- Test Apple Podcasts show links, episode links, direct RSS links, published transcripts, and direct audio links.
- Test one short, one 60-minute, and one 2-hour episode with a listener-owned provider account.
- Confirm podcast audio and transcripts pass through the encrypted Agora cloud job only to the provider authorized by the listener, credentials are erased at job completion, and cloud job records expire within seven days.
- Archive with a distribution certificate, validate the archive, upload it, install through TestFlight, and repeat the critical path.

## Operational Review

- Confirm the podcast ingestion and private transcript workflow is permitted by publisher terms and applicable law.
- Keep the OpenRouter OAuth endpoints and supported model identifiers under release monitoring.
- Establish a support response and incident-response process before release.
