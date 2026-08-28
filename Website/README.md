# The Agora LA Public Site

This Sites project hosts The Agora LA's public product page, Privacy Policy,
Terms of Use, listener support, and the HTTPS return page used by OpenRouter
authorization.

## Local Verification

```sh
npm install
npm test
npm run lint
npm audit --omit=dev
```

The production routes are:

- `/`
- `/privacy`
- `/terms`
- `/support`
- `/auth/openrouter`

The OpenRouter return page does not store credentials. It passes the provider's
authorization query directly back to the iOS app through
`theagorala://openrouter-auth`.

The project has no database, user accounts, or payment processing. Keep
`.openai/hosting.json`, `build/sites-vite-plugin.ts`, and `worker/index.ts` in
place because they are required by Sites deployment.
