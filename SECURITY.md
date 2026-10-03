# Security Policy

## Reporting a Vulnerability

If you discover a security vulnerability in this repository, please report it privately using [GitHub's built-in reporting tool](https://github.com/CommandLineCoding/Elephant/security/advisories). Please do not open a public issue. We appreciate responsible disclosure and will acknowledge your report as soon as possible.

## Scope

Reports are especially welcome for:

- The Go server (`server/`): authentication, JWT/refresh-token handling, OAuth, group authorization and the WebSocket hub
- The E2EE implementation: prekey distribution (`/api/e2ee/*`) and the client's Signal Protocol usage (`mobile/lib/services/signal_service.dart`)
- Local data protection in the mobile app (SQLCipher database and secure storage)

Known limitation: group messages are not yet end-to-end encrypted. See [docs/API_CONTRACTS.md](docs/API_CONTRACTS.md#message-content-format-e2ee).

Thank you for helping to keep Elephant secure!
