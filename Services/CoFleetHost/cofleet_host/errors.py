"""Typed errors shared by the HTTP and service layers."""

from typing import Any, Dict, Optional


class APIError(Exception):
    """An error safe to serialize to an API client."""

    def __init__(
        self,
        status: int,
        code: str,
        message: str,
        details: Optional[Dict[str, Any]] = None,
    ) -> None:
        super().__init__(message)
        self.status = status
        self.code = code
        self.message = message
        self.details = details or {}

    def as_payload(self) -> Dict[str, Any]:
        error: Dict[str, Any] = {"code": self.code, "message": self.message}
        if self.details:
            error["details"] = self.details
        return {"error": error}


class CodexUnavailable(APIError):
    def __init__(self, message: str = "Codex app-server is unavailable.") -> None:
        super().__init__(503, "codex_unavailable", message)


class CodexRPCError(APIError):
    def __init__(self, message: str, rpc_code: Optional[int] = None) -> None:
        details = {"rpcCode": rpc_code} if rpc_code is not None else None
        super().__init__(502, "codex_rpc_error", message, details)
