"""Runtime configuration with secure defaults."""

import ipaddress
import os
import pathlib
from dataclasses import dataclass, field
from typing import Optional, Sequence, Tuple


def _default_data_dir() -> pathlib.Path:
    configured = os.environ.get("COFLEET_DATA_DIR")
    if configured:
        return pathlib.Path(configured).expanduser()
    return pathlib.Path.home() / ".local" / "share" / "cofleet-host"


@dataclass(frozen=True)
class HostConfig:
    data_dir: pathlib.Path = field(default_factory=_default_data_dir)
    bind_host: str = "127.0.0.1"
    port: int = 47831
    display_name: Optional[str] = None
    home: pathlib.Path = field(default_factory=pathlib.Path.home)
    codex_command: Tuple[str, ...] = ("codex", "app-server")
    request_body_limit: int = 1_048_576
    pet_asset_limit: int = 16 * 1024 * 1024
    event_limit: int = 2_000
    interaction_ttl: int = 300
    rpc_timeout: float = 30.0
    require_private_tailscale: bool = False
    event_payload_limit: int = 256 * 1024
    event_storage_limit: int = 16 * 1024 * 1024
    event_replay_limit: int = 200
    event_replay_bytes: int = 2 * 1024 * 1024
    max_concurrent_codex_rpcs: int = 16
    max_active_http_handlers: int = 64
    max_active_sse_streams: int = 16
    http_read_timeout: float = 10.0
    sse_auth_recheck_interval: float = 1.0

    def validate(self) -> "HostConfig":
        host = self.bind_host
        if host == "localhost":
            host = "127.0.0.1"
        try:
            address = ipaddress.ip_address(host)
        except ValueError:
            raise ValueError("cofleet-host must bind to a numeric loopback address")
        if not address.is_loopback:
            raise ValueError(
                "cofleet-host only binds to loopback; publish it with Tailscale Serve, never Funnel"
            )
        if not (0 <= self.port <= 65535):
            raise ValueError("port must be between 0 and 65535")
        if not self.codex_command:
            raise ValueError("codex_command cannot be empty")
        if self.request_body_limit < 1024:
            raise ValueError("request_body_limit is too small")
        if not (4_096 <= self.event_payload_limit <= 2 * 1024 * 1024):
            raise ValueError("event_payload_limit must be between 4 KB and 2 MB")
        if self.event_storage_limit < self.event_payload_limit:
            raise ValueError("event_storage_limit must fit at least one event")
        if not (1 <= self.event_replay_limit <= 1_000):
            raise ValueError("event_replay_limit must be between 1 and 1000")
        if self.event_replay_bytes < self.event_payload_limit:
            raise ValueError("event_replay_bytes must fit at least one event")
        if not (1 <= self.max_concurrent_codex_rpcs <= 128):
            raise ValueError("max_concurrent_codex_rpcs must be between 1 and 128")
        if not (4 <= self.max_active_http_handlers <= 512):
            raise ValueError("max_active_http_handlers must be between 4 and 512")
        if not (1 <= self.max_active_sse_streams < self.max_active_http_handlers):
            raise ValueError("max_active_sse_streams must be below the HTTP handler limit")
        if not (1.0 <= self.http_read_timeout <= 120.0):
            raise ValueError("http_read_timeout must be between 1 and 120 seconds")
        if not (0.25 <= self.sse_auth_recheck_interval <= 10.0):
            raise ValueError("sse_auth_recheck_interval must be between 0.25 and 10 seconds")
        return self

    @property
    def database_path(self) -> pathlib.Path:
        return self.data_dir / "cofleet.sqlite3"

    @property
    def pets_path(self) -> pathlib.Path:
        return self.data_dir / "pets"

    @classmethod
    def with_command(cls, command: Sequence[str], **kwargs: object) -> "HostConfig":
        return cls(codex_command=tuple(command), **kwargs)
