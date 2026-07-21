"""Command-line entry point for serving and pairing CoFleet clients."""

import argparse
import json
import os
import pathlib
import signal
import sys
from typing import Optional, Sequence

from .config import HostConfig
from .http import make_server
from .service import CoFleetHostService
from .tailscale import PrivateServeConfigurationError
from .util import canonical_json


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="cofleet-host")
    parser.add_argument(
        "--data-dir",
        type=pathlib.Path,
        default=None,
        help="Host-owned state directory (default: COFLEET_DATA_DIR or ~/.local/share/cofleet-host)",
    )
    parser.add_argument(
        "--codex",
        default=os.environ.get("COFLEET_CODEX_BIN", "codex"),
        help="Path to the Codex CLI executable",
    )
    subcommands = parser.add_subparsers(dest="command")
    serve = subcommands.add_parser("serve", help="Run the loopback REST/SSE service")
    serve.add_argument("--host", default="127.0.0.1", help="Loopback address only")
    serve.add_argument("--port", type=int, default=47831)
    serve.add_argument("--name", default=None, help="Host display name")
    serve.add_argument(
        "--require-private-tailscale",
        action="store_true",
        help="Fail closed unless active Tailscale Serve config targets this port with Funnel off",
    )
    serve.add_argument(
        "--allow-root-dangerously",
        action="store_true",
        help="Dangerous override; running Codex as root is unsupported",
    )
    subcommands.add_parser("pair", help="Create a one-use ten-minute pairing code")
    subcommands.add_parser("devices", help="List paired devices without printing tokens")
    revoke = subcommands.add_parser("revoke", help="Revoke a paired device")
    revoke.add_argument("device_id")
    return parser


def _config(arguments: argparse.Namespace) -> HostConfig:
    keywords = {
        "codex_command": (arguments.codex, "app-server"),
    }
    if arguments.data_dir is not None:
        keywords["data_dir"] = arguments.data_dir.expanduser()
    if arguments.command == "serve":
        keywords.update(
            {
                "bind_host": arguments.host,
                "port": arguments.port,
                "display_name": arguments.name,
                "require_private_tailscale": arguments.require_private_tailscale,
            }
        )
    return HostConfig(**keywords).validate()


def main(argv: Optional[Sequence[str]] = None) -> int:
    arguments = _parser().parse_args(argv)
    if arguments.command is None:
        arguments.command = "serve"
        arguments.host = "127.0.0.1"
        arguments.port = 47831
        arguments.name = None
        arguments.require_private_tailscale = False
        arguments.allow_root_dangerously = False
    if (
        arguments.command == "serve"
        and hasattr(os, "geteuid")
        and os.geteuid() == 0
        and not arguments.allow_root_dangerously
    ):
        print(
            "cofleet-host: refusing to run Codex as root; use a per-user service "
            "or pass --allow-root-dangerously to override",
            file=sys.stderr,
        )
        return 2
    try:
        config = _config(arguments)
        runs_server = arguments.command == "serve"
        service = CoFleetHostService(
            config,
            start_maintenance=runs_server,
            invalidate_pending_interactions_on_start=runs_server,
        )
    except (ValueError, OSError, RuntimeError, PrivateServeConfigurationError) as error:
        print("cofleet-host: %s" % error, file=sys.stderr)
        return 2
    try:
        if arguments.command == "pair":
            result = service.create_pairing_code("local-cli")
            print(canonical_json(result))
            return 0
        if arguments.command == "devices":
            print(canonical_json({"devices": service.database.list_devices()}))
            return 0
        if arguments.command == "revoke":
            device = service.database.revoke_device(arguments.device_id)
            service.events.publish("device.revoked", {"deviceID": arguments.device_id})
            print(canonical_json({"device": device}))
            return 0
        server = make_server(service)

        def stop(_signum: int, _frame: object) -> None:
            # shutdown must run outside serve_forever's current call stack.
            import threading

            threading.Thread(target=server.shutdown, daemon=True).start()

        signal.signal(signal.SIGINT, stop)
        signal.signal(signal.SIGTERM, stop)
        address, port = server.server_address[:2]
        print(
            canonical_json(
                {
                    "event": "listening",
                    "address": address,
                    "port": port,
                    "publishWith": "tailscale serve --bg http://127.0.0.1:%d" % port,
                    "privateServeVerified": config.require_private_tailscale,
                    "funnelAllowed": False,
                }
            ),
            flush=True,
        )
        server.serve_forever(poll_interval=0.5)
        server.server_close()
        return 0
    except KeyboardInterrupt:
        return 130
    finally:
        service.close()


if __name__ == "__main__":
    raise SystemExit(main())
