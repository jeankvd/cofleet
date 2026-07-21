# Privacy

CoFleet is self-hosted companion software. The project does not operate a cloud
service, advertising network, analytics service, or user database.

## Data processed

Depending on the features you use, CoFleet processes:

- host identity and reachability;
- project roots and source-control summaries;
- Codex task metadata, transcripts, streamed events, and interactions;
- CoFleet notes, todos, per-task settings, and selected pet packages;
- per-device pairing records and event replay cursors.

Codex remains authoritative for account state, tasks, turns, transcripts, and
approvals. A project host is authoritative for CoFleet notes, todos, project
registrations, pet imports, and synchronization metadata.

## Where data lives

- Host-owned data is stored in the host's local SQLite database.
- Apple clients keep UI preferences, bounded caches, and offline note drafts.
- Pairing tokens are stored in Apple Keychain. Widgets and complications use
  credential-free App Group snapshots.
- Multi-host traffic travels directly between your devices over your Tailnet.

CoFleet does not read or copy `~/.codex/auth.json`. Authentication is performed
through supported Codex account and login flows.

## Network access

CoFleet connects only to hosts you pair and to operating-system services needed
for notifications and device relay. The host service is intended for loopback
plus Tailscale Serve, never Tailscale Funnel or unrestricted public ingress.
Codex and Tailscale have their own privacy policies and are separate products.

## Imported pets and attachments

Pet packages are imported only after explicit local selection or discovery in
supported local Codex pet folders. CoFleet validates and copies accepted assets
to its own storage; it does not upload or download pet artwork. Users are
responsible for rights to imported assets.

## Deletion

Unregistering a project removes its CoFleet registration but never deletes the
project directory. Device pairings can be revoked host-by-host. Removing the
host database deletes host-owned CoFleet metadata but not Codex's own history.
