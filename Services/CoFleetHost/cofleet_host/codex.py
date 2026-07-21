"""Long-lived stdio JSONL supervisor for ``codex app-server``."""

import json
import os
import queue
import shutil
import subprocess
import threading
import time
from typing import Any, Callable, Dict, Optional, Sequence

from .errors import CodexRPCError, CodexUnavailable
from .util import canonical_json, new_id


NotificationHandler = Callable[[str, Dict[str, Any]], None]
InteractionHandler = Callable[[str, Any, str, Dict[str, Any]], None]


class CodexAppServerSupervisor:
    INTERACTIVE_METHODS = {
        "item/commandExecution/requestApproval",
        "item/fileChange/requestApproval",
        "item/permissions/requestApproval",
        "item/tool/requestUserInput",
        "mcpServer/elicitation/request",
    }

    def __init__(
        self,
        command: Sequence[str] = ("codex", "app-server"),
        timeout: float = 30.0,
        notification_handler: Optional[NotificationHandler] = None,
        interaction_handler: Optional[InteractionHandler] = None,
        environment: Optional[Dict[str, str]] = None,
        max_concurrent_requests: int = 16,
    ) -> None:
        self.command = tuple(command)
        self.timeout = timeout
        self.notification_handler = notification_handler or (lambda method, params: None)
        self.interaction_handler = interaction_handler or (
            lambda generation, rpc_id, method, params: None
        )
        self.environment = environment
        self._process: Optional[subprocess.Popen[str]] = None
        self._lock = threading.RLock()
        self._write_lock = threading.Lock()
        self._start_lock = threading.Lock()
        self._pending: Dict[int, "queue.Queue[Dict[str, Any]]"] = {}
        self._owned_processes = []  # type: list[subprocess.Popen[str]]
        self._threads = []  # type: list[threading.Thread]
        self._next_id = 1
        self._closed = False
        self._failure_count = 0
        self._retry_after = 0.0
        self._generation: Optional[str] = None
        self._rpc_slots = threading.BoundedSemaphore(max_concurrent_requests)

    @property
    def generation(self) -> Optional[str]:
        with self._lock:
            return self._generation

    def available(self) -> bool:
        executable = self.command[0]
        if os.path.sep in executable:
            return os.path.isfile(executable) and os.access(executable, os.X_OK)
        return shutil.which(executable) is not None

    def close(self) -> None:
        with self._lock:
            self._closed = True
            processes = list(self._owned_processes)
            threads = list(self._threads)
            self._process = None
        for process in processes:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=2.0)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=2.0)
            for stream in (process.stdin, process.stdout, process.stderr):
                if stream is not None:
                    try:
                        stream.close()
                    except OSError:
                        pass
        for thread in threads:
            if thread is not threading.current_thread():
                thread.join(timeout=1.0)

    def request(
        self,
        method: str,
        params: Optional[Dict[str, Any]] = None,
        timeout: Optional[float] = None,
        _skip_start: bool = False,
    ) -> Dict[str, Any]:
        if not _skip_start:
            self._ensure_started()
        # Read-only foreground actions such as “Open in Codex” should briefly
        # wait behind catalog refreshes instead of failing while a slot is about
        # to become available. Explicit short test/caller deadlines still win.
        if not self._rpc_slots.acquire(timeout=min(10.0, timeout or self.timeout)):
            raise CodexUnavailable("Codex is busy; try again shortly.")
        with self._lock:
            request_id = self._next_id
            self._next_id += 1
            response_queue: "queue.Queue[Dict[str, Any]]" = queue.Queue(maxsize=1)
            self._pending[request_id] = response_queue
        try:
            self._write({"id": request_id, "method": method, "params": params or {}})
            try:
                response = response_queue.get(timeout=timeout or self.timeout)
            except queue.Empty:
                raise CodexUnavailable("Codex app-server did not answer in time.")
        finally:
            with self._lock:
                self._pending.pop(request_id, None)
            self._rpc_slots.release()
        if "error" in response:
            error = response.get("error")
            message = error.get("message") if isinstance(error, dict) else str(error)
            code = error.get("code") if isinstance(error, dict) else None
            raise CodexRPCError(message or "Codex rejected the request.", code)
        result = response.get("result", {})
        return result if isinstance(result, dict) else {"value": result}

    def notify(self, method: str, params: Optional[Dict[str, Any]] = None) -> None:
        self._ensure_started()
        self._write({"method": method, "params": params or {}})

    def respond(
        self,
        rpc_id: Any,
        result: Dict[str, Any],
        expected_generation: Optional[str] = None,
    ) -> None:
        self._ensure_started()
        self._write(
            {"id": rpc_id, "result": result}, expected_generation=expected_generation
        )

    def reject(
        self,
        rpc_id: Any,
        message: str,
        code: int = -32602,
        expected_generation: Optional[str] = None,
    ) -> None:
        self._ensure_started()
        self._write(
            {"id": rpc_id, "error": {"code": code, "message": message}},
            expected_generation=expected_generation,
        )

    def _ensure_started(self) -> None:
        with self._lock:
            if self._closed:
                raise CodexUnavailable("The Codex supervisor is shutting down.")
            if self._process is not None and self._process.poll() is None:
                return
        with self._start_lock:
            with self._lock:
                if self._process is not None and self._process.poll() is None:
                    return
                retry_after = self._retry_after
            if time.monotonic() < retry_after:
                raise CodexUnavailable("Codex app-server is restarting; try again shortly.")
            if not self.available():
                raise CodexUnavailable("Codex CLI was not found on this host.")
            self._spawn()
            try:
                self.request(
                    "initialize",
                    {
                        "clientInfo": {
                            "name": "cofleet_host",
                            "title": "CoFleet Host",
                            "version": "0.1.0",
                        },
                        "capabilities": {"experimentalApi": True},
                    },
                    timeout=self.timeout,
                    _skip_start=True,
                )
                self._write({"method": "initialized", "params": {}})
                with self._lock:
                    self._failure_count = 0
                    self._retry_after = 0.0
            except Exception:
                self._mark_failed()
                raise

    def _spawn(self) -> None:
        environment = dict(os.environ if self.environment is None else self.environment)
        process = subprocess.Popen(
            list(self.command),
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            encoding="utf-8",
            errors="replace",
            bufsize=1,
            env=environment,
            shell=False,
        )
        with self._lock:
            self._process = process
            generation = new_id("codexgen")
            self._generation = generation
            self._owned_processes.append(process)
        stdout_thread = threading.Thread(
            target=self._read_stdout, args=(process, generation), daemon=True
        )
        stderr_thread = threading.Thread(target=self._drain_stderr, args=(process,), daemon=True)
        with self._lock:
            self._threads.extend((stdout_thread, stderr_thread))
        stdout_thread.start()
        stderr_thread.start()

    def _write(
        self, envelope: Dict[str, Any], expected_generation: Optional[str] = None
    ) -> None:
        line = canonical_json(envelope) + "\n"
        with self._write_lock:
            with self._lock:
                process = self._process
                generation = self._generation
            if expected_generation is not None and generation != expected_generation:
                raise CodexUnavailable(
                    "The Codex process that requested this interaction has restarted."
                )
            if process is None or process.poll() is not None or process.stdin is None:
                raise CodexUnavailable()
            try:
                process.stdin.write(line)
                process.stdin.flush()
            except (BrokenPipeError, OSError):
                self._mark_failed()
                raise CodexUnavailable()

    def _read_stdout(self, process: "subprocess.Popen[str]", generation: str) -> None:
        if process.stdout is None:
            return
        try:
            for line in process.stdout:
                if len(line) > 8 * 1024 * 1024:
                    continue
                try:
                    envelope = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if not isinstance(envelope, dict):
                    continue
                if "method" in envelope:
                    self._handle_method(envelope, generation)
                elif "id" in envelope:
                    self._handle_response(envelope)
        finally:
            self._mark_failed(process)

    @staticmethod
    def _drain_stderr(process: "subprocess.Popen[str]") -> None:
        # Never log stderr: it may contain user prompts, file paths, or tool output.
        if process.stderr is None:
            return
        for _line in process.stderr:
            pass

    def _handle_response(self, envelope: Dict[str, Any]) -> None:
        request_id = envelope.get("id")
        if type(request_id) is not int:
            return
        with self._lock:
            response_queue = self._pending.get(request_id)
        if response_queue is not None:
            try:
                response_queue.put_nowait(envelope)
            except queue.Full:
                pass

    def _handle_method(self, envelope: Dict[str, Any], generation: str) -> None:
        method = envelope.get("method")
        params = envelope.get("params", {})
        if not isinstance(method, str) or not isinstance(params, dict):
            return
        if "id" in envelope:
            rpc_id = envelope["id"]
            if method not in self.INTERACTIVE_METHODS:
                try:
                    self._write(
                        {
                            "id": rpc_id,
                            "error": {
                                "code": -32601,
                                "message": "Unsupported CoFleet client request",
                            },
                        },
                        expected_generation=generation,
                    )
                except CodexUnavailable:
                    pass
                return
            try:
                self.interaction_handler(generation, rpc_id, method, params)
            except Exception:
                try:
                    self.reject(
                        rpc_id,
                        "CoFleet could not present this request safely.",
                        expected_generation=generation,
                    )
                except Exception:
                    pass
            return
        try:
            self.notification_handler(method, params)
        except Exception:
            # A UI/event reducer must never kill the JSONL reader.
            return

    def _mark_failed(self, process: Optional["subprocess.Popen[str]"] = None) -> None:
        with self._lock:
            if process is not None and process is not self._process:
                return
            current = self._process
            generation = self._generation
            self._process = None
            self._generation = None
            self._failure_count += 1
            delay = min(30.0, 0.25 * (2 ** min(self._failure_count - 1, 7)))
            self._retry_after = time.monotonic() + delay
            pending = list(self._pending.values())
        if current is not None and current.poll() is None:
            try:
                current.terminate()
            except OSError:
                pass
        failure = {"error": {"code": -32001, "message": "Codex app-server exited."}}
        for response_queue in pending:
            try:
                response_queue.put_nowait(failure)
            except queue.Full:
                pass
        try:
            self.notification_handler(
                "cofleet/codexUnavailable",
                {"retryAfterSeconds": delay, "processGeneration": generation},
            )
        except Exception:
            pass
