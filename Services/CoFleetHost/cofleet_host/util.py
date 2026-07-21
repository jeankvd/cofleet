"""Small dependency-free helpers."""

import base64
import hashlib
import hmac
import json
import math
import os
import re
import secrets
import time
import uuid
from typing import Any, Dict, Optional

from .errors import APIError


CONTROL_CHARACTERS = re.compile(r"[\x00-\x1f\x7f]")


def now() -> float:
    return time.time()


def new_id(prefix: str) -> str:
    return "%s_%s" % (prefix, uuid.uuid4().hex)


def canonical_json(value: Any) -> str:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


def json_hash(value: Any) -> str:
    return hashlib.sha256(canonical_json(value).encode("utf-8")).hexdigest()


def token_hash(token: str) -> str:
    return hashlib.sha256(token.encode("utf-8")).hexdigest()


def secure_equal(left: str, right: str) -> bool:
    return hmac.compare_digest(left.encode("ascii"), right.encode("ascii"))


def random_token() -> str:
    # 32 random bytes (256 bits), encoded without padding.
    return secrets.token_urlsafe(32)


def pairing_code() -> str:
    # Ten base32 characters provide 50 bits of entropy while remaining typable.
    alphabet = "23456789ABCDEFGHJKLMNPQRSTUVWXYZ"
    return "".join(secrets.choice(alphabet) for _ in range(10))


def clean_pairing_code(value: str) -> str:
    return "".join(value.upper().split())


def require_string(
    value: Any,
    field: str,
    minimum: int = 1,
    maximum: int = 512,
    allow_control: bool = False,
) -> str:
    if not isinstance(value, str):
        raise APIError(422, "invalid_request", "%s must be a string." % field)
    result = value.strip()
    if len(result) < minimum or len(result) > maximum:
        raise APIError(
            422,
            "invalid_request",
            "%s must contain %d to %d characters." % (field, minimum, maximum),
        )
    if not allow_control and CONTROL_CHARACTERS.search(result):
        raise APIError(422, "invalid_request", "%s contains control characters." % field)
    return result


def bounded_int(
    value: Any,
    field: str,
    default: int,
    minimum: int,
    maximum: int,
) -> int:
    if value is None or value == "":
        return default
    try:
        parsed = int(value)
    except (TypeError, ValueError):
        raise APIError(422, "invalid_request", "%s must be an integer." % field)
    if parsed < minimum or parsed > maximum:
        raise APIError(
            422,
            "invalid_request",
            "%s must be between %d and %d." % (field, minimum, maximum),
        )
    return parsed


def encode_cursor(offset: int) -> str:
    raw = str(offset).encode("ascii")
    return base64.urlsafe_b64encode(raw).decode("ascii").rstrip("=")


def decode_cursor(value: Optional[str]) -> int:
    if not value:
        return 0
    if len(value) > 64:
        raise APIError(422, "invalid_cursor", "The pagination cursor is invalid.")
    try:
        padded = value + "=" * (-len(value) % 4)
        raw = base64.urlsafe_b64decode(padded.encode("ascii"))
        offset = int(raw.decode("ascii"))
    except (ValueError, UnicodeError, OSError):
        raise APIError(422, "invalid_cursor", "The pagination cursor is invalid.")
    if offset < 0 or offset > 10_000_000:
        raise APIError(422, "invalid_cursor", "The pagination cursor is invalid.")
    return offset


def make_etag(kind: str, resource_id: str, revision: int) -> str:
    return 'W/"%s-%s-%d"' % (kind, resource_id, revision)


def parse_etag(value: Optional[str], kind: str, resource_id: str) -> int:
    if not value:
        raise APIError(428, "precondition_required", "If-Match is required.")
    prefix = 'W/"%s-%s-' % (kind, resource_id)
    if not value.startswith(prefix) or not value.endswith('"'):
        raise APIError(412, "revision_conflict", "The resource revision does not match.")
    try:
        revision = int(value[len(prefix) : -1])
    except ValueError:
        raise APIError(412, "revision_conflict", "The resource revision does not match.")
    return revision


def atomic_write(path: str, data: bytes, mode: int = 0o600) -> None:
    directory = os.path.dirname(path)
    os.makedirs(directory, mode=0o700, exist_ok=True)
    temporary = "%s.%s.tmp" % (path, secrets.token_hex(8))
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, mode)
    try:
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
        try:
            directory_fd = os.open(directory, os.O_RDONLY)
            try:
                os.fsync(directory_fd)
            finally:
                os.close(directory_fd)
        except OSError:
            pass
    finally:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass


def positive_finite(value: Any, field: str) -> float:
    try:
        number = float(value)
    except (TypeError, ValueError):
        raise APIError(422, "invalid_request", "%s must be numeric." % field)
    if not math.isfinite(number) or number <= 0:
        raise APIError(422, "invalid_request", "%s must be positive." % field)
    return number


def bounded_json_value(
    value: Any,
    max_nodes: int = 2_000,
    max_depth: int = 12,
    max_string_bytes: int = 32 * 1024,
) -> Any:
    """Return a JSON-safe, structurally bounded copy of provider data."""

    state = {"nodes": 0, "truncated": False}

    def visit(item: Any, depth: int) -> Any:
        state["nodes"] += 1
        if state["nodes"] > max_nodes or depth > max_depth:
            state["truncated"] = True
            return {"_cofleetTruncated": True}
        if item is None or isinstance(item, (bool, int, float)):
            if isinstance(item, float) and not math.isfinite(item):
                state["truncated"] = True
                return None
            return item
        if isinstance(item, str):
            encoded = item.encode("utf-8", errors="replace")
            if len(encoded) <= max_string_bytes:
                return item
            state["truncated"] = True
            shortened = encoded[:max_string_bytes].decode("utf-8", errors="ignore")
            return shortened + "…"
        if isinstance(item, list):
            return [visit(child, depth + 1) for child in item if state["nodes"] <= max_nodes]
        if isinstance(item, dict):
            result: Dict[str, Any] = {}
            for key, child in item.items():
                if state["nodes"] > max_nodes:
                    state["truncated"] = True
                    break
                name = str(key)
                if len(name.encode("utf-8", errors="replace")) > 512:
                    state["truncated"] = True
                    name = name.encode("utf-8", errors="replace")[:512].decode(
                        "utf-8", errors="ignore"
                    )
                result[name] = visit(child, depth + 1)
            return result
        state["truncated"] = True
        return str(item)[:512]

    bounded = visit(value, 0)
    if state["truncated"]:
        if isinstance(bounded, dict):
            bounded["_cofleetTruncated"] = True
        else:
            bounded = {"value": bounded, "_cofleetTruncated": True}
    return bounded
