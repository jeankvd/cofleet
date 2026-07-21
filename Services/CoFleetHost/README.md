# CoFleet Host

`cofleet-host` is a dependency-free Python 3.9+ REST/SSE facade around one
long-lived local `codex app-server` process. Codex owns authentication, tasks,
turns, transcripts, and approvals. The service owns host pairing, project
registration, notes, todos, imported pet packages, durable event replay, and
idempotency records in SQLite.

## Run locally

```sh
python3 -m pip install --user ./Services/CoFleetHost
cofleet-host pair
cofleet-host serve --host 127.0.0.1 --port 47831
```

The server deliberately rejects non-loopback bind addresses. Publish the
loopback backend only to authenticated Tailnet peers with Tailscale Serve:

```sh
tailscale serve --bg http://127.0.0.1:47831
cofleet-host serve --host 127.0.0.1 --port 47831 --require-private-tailscale
```

Do **not** run `tailscale funnel`. HTTP headers cannot reliably prove whether a
request arrived through Serve or Funnel. In private mode, startup instead
inspects `tailscale serve status --json`, refuses any active Funnel permission,
and requires a matching proxy to the configured loopback port. Requests must
also carry the identity headers added by Tailscale Serve, as well as a CoFleet
bearer token. A local development server may omit the private-mode flag, but it
must not be treated as proof of a private Tailnet deployment.

Each Apple client redeems a one-use pairing code and stores its returned
256-bit bearer token in Keychain; only the token hash is stored by the host.

Account authentication remains owned by Codex. CoFleet can request the
app-server's ChatGPT device-code flow; when that flow is not supported by the
installed Codex version, authenticate the same unprivileged service account
with `codex login` and then refresh CoFleet. Never copy `~/.codex/auth.json`
into CoFleet configuration.

Run CoFleet Host as the same unprivileged user who owns the Codex login and
projects. The CLI refuses to serve as root unless the explicitly dangerous
override is supplied.

- macOS: copy the example only to
  `~/Library/LaunchAgents/com.cofleet.host.plist`, replace every placeholder
  with an absolute user-owned path, then use `launchctl bootstrap gui/$(id -u)`.
- Linux: copy the unit only to
  `~/.config/systemd/user/cofleet-host.service`, then use
  `systemctl --user daemon-reload` and `systemctl --user enable --now
  cofleet-host`.

Never install either example as a LaunchDaemon or system unit. Both templates
bind to loopback and fail closed unless private Tailscale Serve is configured.
They deliberately do not apply filesystem sandboxes because Codex access
profiles range from workspace-write to full access; the unprivileged service
account remains the operating-system boundary.

## Tests

From the repository root:

```sh
PYTHONPATH=Services/CoFleetHost python3 -m unittest discover -s Tests/HostTests -v
```

The repository also contains explicit, opt-in integration smokes. They are not
part of CI or `Scripts/publication-gate.sh` because live turns consume usage and
Tailnet checks require operator-owned hosts:

```sh
# No task or turn creation; redacted output only.
Scripts/smoke-live-codex.py --read-only

# Consumes Codex usage and archives its synthetic task in cleanup.
Scripts/smoke-live-codex.py --safe-turn --confirm-live-usage
Scripts/smoke-live-codex.py --approval-probes --confirm-live-usage
```

To check two deployed hosts, create one-use codes with `cofleet-host pair` on
each host, then provide the two private HTTPS `*.ts.net` origins to
`Scripts/smoke-tailnet.py`. Codes are read with hidden prompts, bearer tokens
stay in memory, cross-host token use must fail, and both temporary devices are
self-revoked even when verification fails. The Tailnet smoke is read-only with
respect to projects and Codex tasks.

These tools redact response bodies, account fields, filesystem paths, task
titles/transcripts, tokens, and subprocess stderr. A local read-only smoke may
still cause Codex to initialize or repair its own state database.

The checked-in API contract is [`../../Docs/openapi.yaml`](../../Docs/openapi.yaml).
