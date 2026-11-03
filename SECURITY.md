# Security Policy

SwiftDesk lets one Mac control another, so security reports are taken seriously.

## Reporting a vulnerability

Please **do not open a public issue**. Report it privately through
[GitHub Security Advisories](https://github.com/shivaluma/swiftdesk/security/advisories/new).

Include what you found, how to reproduce it, and the SwiftDesk and macOS versions. You should get a reply within a few days.

## Security model in brief

- Every connection is QUIC with **TLS 1.3 and mutual certificate authentication**. Each Mac has its own device identity, and the Host sees the Viewer's fingerprint before allowing control.
- The Host must **approve each session** (Allow / Deny), unless the Host owner has explicitly turned on password access.
- Password access uses a challenge–response, so the password never crosses the network, and repeated wrong guesses are locked out.
- Control is granted only for the current session. When it ends, held keys and mouse buttons are released and input is rejected.
- SwiftDesk has **no cloud accounts and no relay servers**: traffic goes directly between your Macs (or through your own Tailscale network).

## Supported versions

Only the latest release receives security fixes.
