import pathlib
import tempfile
from typing import Any, Dict, List, Optional, Tuple

from cofleet_host.config import HostConfig
from cofleet_host.service import CoFleetHostService


class FakeCodex:
    def __init__(self) -> None:
        self.requests: List[Tuple[str, Dict[str, Any]]] = []
        self.responses: Dict[str, Any] = {}
        self.responded: List[Tuple[Any, Dict[str, Any]]] = []
        self.rejected: List[Tuple[Any, str]] = []
        self.notification_handler = None
        self.interaction_handler = None
        self.closed = False
        self.generation = "fake-generation-1"

    def available(self) -> bool:
        return True

    def request(self, method: str, params: Optional[Dict[str, Any]] = None, **_kwargs: Any) -> Dict[str, Any]:
        payload = params or {}
        self.requests.append((method, payload))
        response = self.responses.get(method, {})
        if isinstance(response, list):
            if not response:
                return {}
            return response.pop(0)
        if callable(response):
            return response(payload)
        return response

    def respond(
        self,
        rpc_id: Any,
        result: Dict[str, Any],
        expected_generation: Optional[str] = None,
    ) -> None:
        if expected_generation != self.generation:
            raise RuntimeError("stale generation")
        self.responded.append((rpc_id, result))

    def reject(
        self,
        rpc_id: Any,
        message: str,
        code: int = -32602,
        expected_generation: Optional[str] = None,
    ) -> None:
        if expected_generation != self.generation:
            raise RuntimeError("stale generation")
        self.rejected.append((rpc_id, message))

    def close(self) -> None:
        self.closed = True


class ServiceFixture:
    def __init__(self, interaction_ttl: int = 300, **config_overrides: Any) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.temporary.name)
        self.home = self.root / "home"
        self.home.mkdir()
        self.codex = FakeCodex()
        config_values = dict(
            data_dir=self.root / "state",
            home=self.home,
            port=0,
            interaction_ttl=interaction_ttl,
        )
        config_values.update(config_overrides)
        self.config = HostConfig(**config_values)
        self.service = CoFleetHostService(
            self.config,
            codex=self.codex,
            start_maintenance=False,
            private_serve_verifier=lambda port: {
                "verified": True,
                "proxyTargets": ["http://127.0.0.1:%d" % port],
                "funnelAllowed": False,
            },
        )

    def pair(self, name: str = "Test iPhone") -> Tuple[Dict[str, Any], str]:
        pairing = self.service.create_pairing_code("test")
        result = self.service.redeem_pairing({"code": pairing["code"], "deviceName": name})
        return result["device"], result["token"]

    def project(self, name: str = "Example") -> Dict[str, Any]:
        root = self.root / name
        root.mkdir(exist_ok=True)
        return self.service.database.create_project(name, str(root), str(root.resolve()))

    def close(self) -> None:
        self.service.close()
        self.temporary.cleanup()
