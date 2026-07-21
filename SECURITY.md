# Security Policy

## Supported versions

Until CoFleet reaches 1.0, security fixes are made on the current `main` branch
and the newest tagged release only.

## Reporting a vulnerability

Do not open a public issue for a suspected vulnerability. Once the repository
is published, use GitHub's private vulnerability reporting at
`https://github.com/jeankvd/cofleet/security/advisories/new`. Include:

- the affected commit or version;
- the relevant Apple platform or host platform;
- reproduction steps with synthetic data;
- impact and any known mitigations.

Do not include real pairing tokens, Codex credentials, private task content,
Tailnet addresses, or personal filesystem paths. Maintainers will acknowledge a
complete report as soon as practical, coordinate a fix, and credit reporters
who want attribution.

## Security boundaries

- `cofleet-host` must bind to loopback and may be published privately only
  through Tailscale Serve. Funnel/public exposure is unsupported.
- Pairing codes are single-use and expire after ten minutes. Device tokens are
  independently revocable and stored as hashes on the host.
- Apple clients store raw device tokens in Keychain. Widgets and Watch
  complications consume credential-free App Group snapshots.
- Codex owns account authentication. CoFleet must not read, copy, export, or
  log Codex credential files.
- Paths must be canonicalized beneath the operation's allowed boundary. Never
  follow a symlink to bypass that boundary or elevate filesystem privileges.
- Approvals and questions are exactly-once interactions. Offline approvals are
  never queued.

## Hardening expectations

Security-sensitive pull requests should cover authentication failures, request
size limits, traversal and symlink attacks, replay, expiry, idempotency,
redaction, event replay bounds, and process restart behavior. Run
`Scripts/check-repository.sh` before sharing a branch.
