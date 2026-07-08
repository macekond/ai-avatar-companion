# Security Policy

Nova is a **local-first** application: audio, transcripts, and the child's
profile stay on the device. There is no server, account, or telemetry
uploaded anywhere.

## Reporting a vulnerability

If you find a security issue, please **do not open a public issue**. Instead,
email the maintainer or use GitHub's [private vulnerability reporting](https://docs.github.com/en/code-security/security-advisories/guidance-on-reporting-and-writing-information-about-vulnerabilities/privately-reporting-a-security-vulnerability)
("Report a vulnerability" on the Security tab). You'll get a response as soon
as reasonably possible.

## Scope / design notes

- The Python sidecar listens only on `localhost:8765` and enforces a
  WebSocket **Origin allow-list** so other web pages can't reach the mic.
- Profile slugs from the client are **sanitized server-side** to prevent
  path traversal.
- The bundled macOS app is **ad-hoc signed**, not notarized — first launch
  requires right-click → Open.
- Ollama runs as a separate local process the app does not manage.
