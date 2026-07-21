"""Fail-closed verification for a private Tailscale Serve deployment."""

import json
import shutil
import subprocess
from typing import Any, Dict, Iterable, List, Optional
from urllib.parse import urlsplit


class PrivateServeConfigurationError(RuntimeError):
    pass


def _allow_funnel_values(value: Any) -> Iterable[Any]:
    if isinstance(value, dict):
        for key, child in value.items():
            if str(key).casefold() == "allowfunnel":
                yield child
            yield from _allow_funnel_values(child)
    elif isinstance(value, list):
        for child in value:
            yield from _allow_funnel_values(child)


def _has_truthy_flag(value: Any) -> bool:
    if isinstance(value, dict):
        return any(_has_truthy_flag(child) for child in value.values())
    if isinstance(value, list):
        return any(_has_truthy_flag(child) for child in value)
    return value is True or (isinstance(value, (int, float)) and value != 0)


def _proxy_targets(value: Any) -> List[str]:
    targets: List[str] = []
    if isinstance(value, dict):
        for key, child in value.items():
            if str(key).casefold() == "proxy" and isinstance(child, str):
                targets.append(child)
            targets.extend(_proxy_targets(child))
    elif isinstance(value, list):
        for child in value:
            targets.extend(_proxy_targets(child))
    return targets


def _matches_loopback(target: str, port: int) -> bool:
    try:
        parsed = urlsplit(target)
        target_port = parsed.port
    except ValueError:
        return False
    return (
        parsed.scheme in ("http", "https")
        and parsed.hostname in ("127.0.0.1", "::1", "localhost")
        and target_port == port
    )


def verify_private_serve(
    port: int,
    tailscale_executable: Optional[str] = None,
    timeout: float = 5.0,
) -> Dict[str, Any]:
    """Prove the active Serve config targets this loopback port with Funnel off.

    HTTP requests cannot reliably distinguish Serve from Funnel using a marker
    header. Deployment therefore verifies tailscaled's own configuration before
    starting, then the HTTP layer requires Serve-added identity headers.
    """

    executable = tailscale_executable or shutil.which(
        "tailscale", path="/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin"
    )
    if not executable:
        raise PrivateServeConfigurationError("Tailscale CLI was not found.")
    environment = {
        "PATH": "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin",
        "LANG": "C",
        "LC_ALL": "C",
    }
    try:
        completed = subprocess.run(
            [executable, "serve", "status", "--json"],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            encoding="utf-8",
            errors="strict",
            timeout=timeout,
            check=False,
            env=environment,
        )
    except (OSError, subprocess.TimeoutExpired, UnicodeError) as error:
        raise PrivateServeConfigurationError(
            "Could not verify the active Tailscale Serve configuration."
        ) from error
    if completed.returncode != 0 or len(completed.stdout.encode("utf-8")) > 2 * 1024 * 1024:
        raise PrivateServeConfigurationError(
            "Could not verify the active Tailscale Serve configuration."
        )
    try:
        config = json.loads(completed.stdout)
    except json.JSONDecodeError as error:
        raise PrivateServeConfigurationError("Tailscale returned invalid Serve JSON.") from error
    if not isinstance(config, dict):
        raise PrivateServeConfigurationError("Tailscale returned an invalid Serve configuration.")
    if any(_has_truthy_flag(value) for value in _allow_funnel_values(config)):
        raise PrivateServeConfigurationError(
            "Tailscale Funnel is enabled for an active Serve endpoint; refusing to start."
        )
    targets = _proxy_targets(config)
    matching = [target for target in targets if _matches_loopback(target, port)]
    if not matching:
        raise PrivateServeConfigurationError(
            "No private Tailscale Serve proxy targets this CoFleet loopback port."
        )
    return {"verified": True, "proxyTargets": matching, "funnelAllowed": False}
