# Contributing to CoFleet

Thank you for helping make CoFleet safer and more useful. Contributions of
code, tests, documentation, accessibility improvements, and reproducible bug
reports are welcome.

## Before opening a change

1. Discuss large architectural or product changes in an issue first.
2. Do not copy proprietary application code, credentials, private host data,
   conversation transcripts, or artwork you cannot redistribute.
3. Keep CoFleet's public provider surface Codex-only unless a separate proposal
   has been accepted.
4. Preserve host-scoped identifiers and the rule that Codex remains canonical
   for tasks, turns, authentication, and approvals.

## Development setup

```bash
brew bundle
cp Config/Local.xcconfig.example Config/Local.xcconfig
Scripts/bootstrap.sh
Scripts/test.sh
```

Run the checks closest to your change while iterating, then run the complete
suite before requesting review. Build scripts do not install or launch apps.

## Code style

- Swift: Swift 6, explicit concurrency boundaries, value types for wire models,
  dependency injection at I/O boundaries, and platform-specific code behind
  compile-time guards.
- Python: Python 3.9 compatibility, standard-library-first, type annotations on
  public APIs, bounded inputs, and no logging of secrets or prompt bodies.
- Shell: POSIX-conscious Bash with `set -euo pipefail`; pass ShellCheck.
- API changes: update the checked-in OpenAPI contract and compatibility tests.
- User-facing changes: preserve VoiceOver labels, Dynamic Type, keyboard
  navigation, reduced-motion behavior, and small Watch layouts.

## Tests

Every behavior change should include focused coverage. Security-sensitive
changes require negative tests for malformed, expired, replayed, and
unauthorized requests.

```bash
Scripts/check-repository.sh
swift test --package-path Packages/CoFleetKit
PYTHONPATH=Services/CoFleetHost python3 -m unittest discover -s Tests/HostTests -v
Scripts/build.sh all
```

Simulator UI tests are intentionally opt-in locally:

```bash
Scripts/test.sh --ui
```

Maintainers preparing a migration may put personal host, project, or product
names in the ignored `Config/private-terms.local.txt` file, one fixed string per
line. Repository checks include that file when present without adding those
private values to Git.

## Commits and pull requests

- Use concise conventional commit subjects such as `feat(watch): restore turn
  completion` or `fix(host): reject replayed pairing code`.
- Keep generated `CoFleet.xcodeproj` synchronized with `project.yml`.
- Explain user-visible behavior, test evidence, security implications, and any
  migration in the pull request body.
- Keep unrelated formatting or generated changes out of the pull request.

By contributing, you agree that your contribution is licensed under the same
GPL-3.0-only terms and Section 7 permission as the project.
