# Security

## Reporting a vulnerability

Do not open a public issue for security problems. Use GitHub's private vulnerability
reporting on this repository (Security > Report a vulnerability).

Include the app version and build, the affected component, the impact and a minimal
reproduction. Do not include live credentials, other people's data, signed stream URLs,
account cookies, private keys or provisioning profiles.

If a credential is exposed, revoke or rotate it with its issuer right away. Removing it from
the source does not remove it from history, forks or build artifacts.

## Scope

- The app has no servers or accounts of its own. Kick sign-in happens on kick.com's own page
  inside the app. Session cookies stay in the system web store on your device.
- The IPA is distributed unsigned. You sign it with your own certificate or Apple ID.
- There is no supported-version matrix. Fixes ship in the next build.

## CI and publication rules

- CI runs on fresh GitHub-hosted runners with read-only repository access, commit-pinned
  actions, no persisted checkout credentials, no repository secrets and no
  `pull_request_target`. Pull request builds never publish artifacts.
- The Amazon IVS SDK is downloaded from its public AWS distribution. It is checked against a pinned
  SHA-256 and its Apple/Amazon signature. Its privacy manifest is preserved.
- Never commit signing material, IPAs, logs with stream URLs or a shared OAuth client secret.
