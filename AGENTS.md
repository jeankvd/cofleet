# AGENTS.md

## Project overview

CoFleet for Codex is a Swift 6 Apple companion backed by a Python 3.9+ host
service. Codex is canonical for account state, tasks, turns, transcripts, and
interactions. The host is canonical for project registrations, notes, todos,
pet imports, event replay, and idempotency.

Key boundaries:

- `Apps/`: thin platform shells for macOS, iOS, watchOS, and WidgetKit.
- `Packages/CoFleetKit/`: shared Swift models, transport, Codex adaptation, and
  UI. Keep platform-specific behavior behind compile-time guards.
- `Services/CoFleetHost/`: loopback-only REST/SSE facade and stdio JSONL Codex
  process owner. Preserve Python 3.9 compatibility.
- `project.yml`: authoritative XcodeGen project definition.

Do not introduce alternate harnesses, private topology, fixed user paths,
bundled pet art, credential scraping, public host exposure, or accessibility
automation of another app.

## Setup commands

```bash
brew bundle
cp Config/Local.xcconfig.example Config/Local.xcconfig
Scripts/bootstrap.sh
Scripts/doctor.sh
```

`Config/Local.xcconfig` is ignored and must contain only local identifiers and
signing choices. Never commit credentials, device tokens, host databases, task
transcripts, or provisioning material.

## Development workflow

- Regenerate Xcode after changing `project.yml`: `Scripts/generate-project.sh`.
- Build without installing: `Scripts/build.sh <macos|ios-simulator|ios-device|watch|all>`.
- Install only through an explicit `Scripts/install-*.sh` command.
- Inspect the host CLI with `PYTHONPATH=Services/CoFleetHost python3 -m cofleet_host --help`.
- Treat the checked-in OpenAPI contract as a compatibility boundary. Update
  models, server behavior, and contract tests together.

## Testing instructions

```bash
Scripts/test.sh
swift test --package-path Packages/CoFleetKit
PYTHONPATH=Services/CoFleetHost python3 -m unittest discover -s Tests/HostTests -v
Scripts/check-repository.sh
Scripts/check-project-drift.sh
```

Use `Scripts/test.sh --ui` for local simulator UI smoke tests. Live Codex and
Tailnet tests must be opt-in, use temporary synthetic projects, and must never
mutate a user's real task history or project data.

## Code style

- Prefer small focused stores and injected I/O boundaries over global state.
- Keep wire identifiers host-scoped and preserve unknown enum values/events for
  forward compatibility.
- Bound every page, body, asset, replay buffer, timeout, and retry loop.
- Redact tokens, commands, prompts, paths, transcripts, and environment values
  from logs.
- Use actor isolation or `Sendable` value types for Swift concurrency.
- Use type annotations and deterministic standard-library implementations in
  Python where practical.
- Add accessibility labels and test responsive behavior for every new surface.

## Build and deployment

Deployment floors are macOS 14, iOS 17, and watchOS 10. CI builds unsigned
products. Signing, installation, notarization, GitHub publication, and App Store
submission are separate explicit operations.

The host must bind to loopback. Tailscale Serve may publish that loopback port
privately; Tailscale Funnel is unsupported and must be rejected.

## Pull request guidelines

- Use conventional commit subjects.
- Include behavior, tests, security/privacy impact, and migration notes.
- Keep generated `CoFleet.xcodeproj` synchronized with `project.yml`.
- Run repository hygiene, Swift tests, host tests, and relevant unsigned builds.
- Do not include personal paths, real hosts/IPs, real conversations, secrets,
  unexplained binaries, or assets without redistribution rights.
