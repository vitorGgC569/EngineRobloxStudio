from __future__ import annotations

import base64
import binascii
import hashlib
import json
import os
import queue
import subprocess
import threading
import time
from collections import deque
from pathlib import Path
from typing import Any, Protocol, Sequence

from .transport import (
    MAX_RPC_REQUEST_BYTES,
    MAX_RPC_RESPONSE_BYTES,
    RpcTransport,
    TransportError,
)


MCP_PROTOCOL_VERSION = "2025-06-18"
OFFICIAL_CANONICAL_METHODS = frozenset({
    "playtest_start",
    "playtest_stop",
    "screen_capture",
    "console_read",
    "character_navigation",
    "user_keyboard_input",
    "user_mouse_input",
})


class NativeStudioMcpError(TransportError):
    pass


class NativeStudioToolUnavailable(NativeStudioMcpError):
    pass


class McpClient(Protocol):
    def list_tools(self) -> list[dict[str, Any]]: ...
    def call_tool(self, name: str, arguments: dict[str, Any]) -> Any: ...
    def close(self) -> None: ...


class StdioMcpClient:
    """Minimal persistent MCP stdio client for Studio's built-in MCP server.

    It launches only StudioMCP/mcp.bat, never Roblox Studio itself. If Studio is
    closed or MCP is disabled, tool calls fail; this client does not cold-launch
    or focus Studio.
    """

    def __init__(
        self,
        command: Sequence[str] | None = None,
        *,
        timeout: float = 20.0,
        protocol_version: str = MCP_PROTOCOL_VERSION,
    ) -> None:
        self.command = list(command) if command is not None else self.default_command()
        self.timeout = float(timeout)
        self.protocol_version = protocol_version
        self._process: subprocess.Popen[str] | None = None
        self._reader: threading.Thread | None = None
        self._stderr_reader: threading.Thread | None = None
        self._messages: queue.Queue[dict[str, Any]] = queue.Queue()
        self._stderr_tail: deque[str] = deque(maxlen=40)
        self._next_id = 1
        self._initialized = False
        self._lock = threading.RLock()
        self._tools: list[dict[str, Any]] | None = None

    @staticmethod
    def default_command() -> list[str]:
        if os.name == "nt":
            local = os.environ.get("LOCALAPPDATA")
            if not local:
                raise NativeStudioMcpError(
                    "LOCALAPPDATA is not set; cannot locate Roblox Studio MCP"
                )
            script = Path(local) / "Roblox" / "mcp.bat"
            if not script.is_file():
                raise NativeStudioMcpError(
                    f"Roblox Studio MCP launcher is not installed at {script}"
                )
            return ["cmd.exe", "/d", "/s", "/c", str(script)]

        mac = Path("/Applications/RobloxStudio.app/Contents/MacOS/StudioMCP")
        if mac.is_file():
            return [str(mac)]
        raise NativeStudioMcpError(
            "Roblox Studio MCP launcher was not found on this platform"
        )

    def _stderr_loop(self, stream: Any) -> None:
        try:
            for line in stream:
                value = str(line).rstrip()
                if value:
                    self._stderr_tail.append(value)
        except Exception:
            return

    def _stdout_loop(self, stream: Any) -> None:
        try:
            for line in stream:
                raw = str(line).strip()
                if not raw:
                    continue
                if len(raw.encode("utf-8")) > MAX_RPC_RESPONSE_BYTES:
                    self._messages.put({
                        "jsonrpc": "2.0",
                        "error": {
                            "code": -32099,
                            "message": "Studio MCP response exceeded the RQE response limit",
                        },
                    })
                    continue
                try:
                    payload = json.loads(raw)
                except json.JSONDecodeError:
                    # MCP stdout must be protocol-only. Ignore non-JSON chatter
                    # instead of treating it as a tool response.
                    continue
                if isinstance(payload, dict):
                    self._messages.put(payload)
        finally:
            self._messages.put({
                "jsonrpc": "2.0",
                "error": {
                    "code": -32098,
                    "message": "Studio MCP process closed its stdout",
                },
            })

    def _start(self) -> None:
        if self._process is not None and self._process.poll() is None:
            return

        creationflags = 0
        if os.name == "nt":
            creationflags = int(getattr(subprocess, "CREATE_NO_WINDOW", 0))

        try:
            self._process = subprocess.Popen(
                self.command,
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                encoding="utf-8",
                errors="replace",
                bufsize=1,
                creationflags=creationflags,
            )
        except OSError as exc:
            raise NativeStudioMcpError(
                f"could not start Roblox Studio MCP transport: {exc}"
            ) from exc

        assert self._process.stdout is not None
        assert self._process.stderr is not None
        self._reader = threading.Thread(
            target=self._stdout_loop,
            args=(self._process.stdout,),
            name="rqe-studio-mcp-stdout",
            daemon=True,
        )
        self._stderr_reader = threading.Thread(
            target=self._stderr_loop,
            args=(self._process.stderr,),
            name="rqe-studio-mcp-stderr",
            daemon=True,
        )
        self._reader.start()
        self._stderr_reader.start()

    def _send(self, payload: dict[str, Any]) -> None:
        self._start()
        assert self._process is not None and self._process.stdin is not None
        encoded = json.dumps(
            payload, separators=(",", ":"), ensure_ascii=False
        )
        encoded_bytes = encoded.encode("utf-8")
        if len(encoded_bytes) > MAX_RPC_REQUEST_BYTES:
            raise NativeStudioMcpError(
                f"Studio MCP request exceeds {MAX_RPC_REQUEST_BYTES} bytes"
            )
        try:
            self._process.stdin.write(encoded + "\n")
            self._process.stdin.flush()
        except (BrokenPipeError, OSError) as exc:
            detail = " | ".join(self._stderr_tail)
            raise NativeStudioMcpError(
                f"Studio MCP stdin closed: {exc}" + (f" ({detail})" if detail else "")
            ) from exc

    def _request(self, method: str, params: dict[str, Any]) -> Any:
        request_id = self._next_id
        self._next_id += 1
        self._send({
            "jsonrpc": "2.0",
            "id": request_id,
            "method": method,
            "params": params,
        })

        deadline = time.monotonic() + self.timeout
        pending: list[dict[str, Any]] = []
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                detail = " | ".join(self._stderr_tail)
                raise NativeStudioMcpError(
                    f"Studio MCP timed out waiting for {method}"
                    + (f" ({detail})" if detail else "")
                )
            try:
                message = self._messages.get(timeout=remaining)
            except queue.Empty as exc:
                detail = " | ".join(self._stderr_tail)
                raise NativeStudioMcpError(
                    f"Studio MCP timed out waiting for {method}"
                    + (f" ({detail})" if detail else "")
                ) from exc
            if message.get("id") != request_id:
                if "id" not in message and "error" in message:
                    detail = " | ".join(self._stderr_tail)
                    raise NativeStudioMcpError(
                        f"Studio MCP transport failed while waiting for {method}: "
                        f"{message['error']}"
                        + (f" ({detail})" if detail else "")
                    )
                # Notifications have no id. A response for another request is
                # impossible under this serialized lock, but preserve it if a
                # future implementation allows concurrency.
                if "id" in message:
                    pending.append(message)
                continue
            for item in pending:
                self._messages.put(item)
            if "error" in message:
                raise NativeStudioMcpError(
                    f"Studio MCP {method} failed: {message['error']}"
                )
            return message.get("result")

    def _initialize(self) -> None:
        if self._initialized:
            return
        with self._lock:
            if self._initialized:
                return
            result = self._request(
                "initialize",
                {
                    "protocolVersion": self.protocol_version,
                    "capabilities": {},
                    "clientInfo": {
                        "name": "Roblox Quality Engine",
                        "version": "0.2.0",
                    },
                },
            )
            if not isinstance(result, dict):
                raise NativeStudioMcpError(
                    "Studio MCP initialize returned a malformed response"
                )
            self._send({
                "jsonrpc": "2.0",
                "method": "notifications/initialized",
                "params": {},
            })
            self._initialized = True

    @staticmethod
    def _unwrap_tool_result(result: Any) -> Any:
        if not isinstance(result, dict):
            return result
        if result.get("isError") is True:
            raise NativeStudioMcpError(
                f"Studio MCP tool reported an error: {result.get('content')}"
            )
        if "structuredContent" in result:
            return result["structuredContent"]

        content = result.get("content")
        if not isinstance(content, list) or not content:
            return result
        if len(content) == 1 and isinstance(content[0], dict):
            item = content[0]
            if item.get("type") == "text" and isinstance(item.get("text"), str):
                text = item["text"]
                try:
                    return json.loads(text)
                except json.JSONDecodeError:
                    return text
        # Images and mixed text/image results must remain lossless.
        return result

    def list_tools(self) -> list[dict[str, Any]]:
        self._initialize()
        with self._lock:
            if self._tools is None:
                collected: list[dict[str, Any]] = []
                cursor: str | None = None
                for _page in range(10):
                    params = {"cursor": cursor} if cursor else {}
                    result = self._request("tools/list", params)
                    tools = result.get("tools") if isinstance(result, dict) else None
                    if not isinstance(tools, list):
                        raise NativeStudioMcpError(
                            "Studio MCP tools/list returned no tools array"
                        )
                    collected.extend(
                        item for item in tools if isinstance(item, dict)
                    )
                    next_cursor = (
                        result.get("nextCursor")
                        if isinstance(result, dict)
                        else None
                    )
                    if not next_cursor:
                        break
                    cursor = str(next_cursor)
                else:
                    raise NativeStudioMcpError(
                        "Studio MCP tools/list exceeded 10 pages"
                    )
                self._tools = collected
            return list(self._tools)

    def call_tool(self, name: str, arguments: dict[str, Any]) -> Any:
        self._initialize()
        with self._lock:
            result = self._request(
                "tools/call",
                {"name": name, "arguments": arguments},
            )
        return self._unwrap_tool_result(result)

    def close(self) -> None:
        process = self._process
        self._process = None
        self._initialized = False
        self._tools = None
        if process is None:
            return
        try:
            if process.stdin:
                process.stdin.close()
        except OSError:
            pass
        try:
            process.terminate()
            process.wait(timeout=2)
        except Exception:
            try:
                process.kill()
            except Exception:
                pass

    def __enter__(self) -> "StdioMcpClient":
        return self

    def __exit__(self, *_args: Any) -> None:
        self.close()


class RobloxStudioMcpTransport:
    """Canonical RQE operations over Roblox Studio's built-in MCP server.

    Studio selection is explicit and fail-closed. With multiple instances open,
    the transport never guesses which one should receive a mutation.
    """

    TOOL_ALIASES = {
        "playtest_start": "start_stop_play",
        "playtest_stop": "start_stop_play",
        "screen_capture": "screen_capture",
        "console_read": "get_console_output",
        "character_navigation": "character_navigation",
        "user_keyboard_input": "user_keyboard_input",
        "user_mouse_input": "user_mouse_input",
    }

    def __init__(
        self,
        client: McpClient | None = None,
        *,
        studio_id: str | None = None,
        place_name: str | None = None,
        place_id: int | None = None,
    ) -> None:
        self.client = client or StdioMcpClient()
        self.studio_id = studio_id
        self.place_name = place_name
        self.place_id = int(place_id) if place_id is not None else None
        self._tools: dict[str, dict[str, Any]] | None = None
        self._selected: dict[str, Any] | None = None
        self._capture_sequence = 0

    def _tool_map(self) -> dict[str, dict[str, Any]]:
        if self._tools is None:
            self._tools = {
                str(item.get("name")): item
                for item in self.client.list_tools()
                if item.get("name")
            }
        return self._tools

    def _require_tool(self, name: str) -> dict[str, Any]:
        tool = self._tool_map().get(name)
        if tool is None:
            raise NativeStudioToolUnavailable(
                f"Roblox Studio MCP does not expose required tool {name!r}"
            )
        return tool

    @staticmethod
    def _studio_records(value: Any) -> list[dict[str, Any]]:
        records: list[dict[str, Any]] = []

        def visit(node: Any) -> None:
            if isinstance(node, dict):
                keys = {str(key).lower() for key in node}
                if (
                    "studio_id" in keys
                    or "studioid" in keys
                    or "studioinstanceid" in keys
                ):
                    records.append(node)
                    return
                for child in node.values():
                    visit(child)
            elif isinstance(node, list):
                for child in node:
                    visit(child)

        visit(value)
        return records

    @staticmethod
    def _field(record: dict[str, Any], *names: str) -> Any:
        normalized = {str(key).lower(): value for key, value in record.items()}
        for name in names:
            if name.lower() in normalized:
                return normalized[name.lower()]
        return None

    def select_studio(self, *, refresh: bool = False) -> dict[str, Any]:
        if self._selected is not None and not refresh:
            return dict(self._selected)

        self._require_tool("list_roblox_studios")
        raw = self.client.call_tool("list_roblox_studios", {})
        studios = self._studio_records(raw)
        if not studios:
            raise NativeStudioMcpError(
                "Roblox Studio MCP is connected, but no Studio instances are available"
            )

        if self.studio_id:
            matches = [
                item for item in studios
                if str(self._field(
                    item, "studio_id", "studioId", "studioInstanceId"
                ) or "") == self.studio_id
            ]
        else:
            matches = list(studios)
            if self.place_id is not None:
                matches = [
                    item for item in matches
                    if int(self._field(item, "place_id", "placeId") or 0)
                    == self.place_id
                ]
            if self.place_name:
                wanted = self.place_name.casefold()
                matches = [
                    item for item in matches
                    if str(self._field(
                        item, "name", "place_name", "placeName"
                    ) or "").casefold() == wanted
                ]

        if len(matches) != 1:
            visible = [
                {
                    "studio_id": self._field(
                        item, "studio_id", "studioId", "studioInstanceId"
                    ),
                    "name": self._field(item, "name", "place_name", "placeName"),
                    "place_id": self._field(item, "place_id", "placeId"),
                }
                for item in studios
            ]
            raise NativeStudioMcpError(
                "Studio selection is ambiguous or missing; choose an exact "
                f"studio_id/place. Connected studios: {visible}"
            )

        selected = matches[0]
        selected_id = self._field(
            selected, "studio_id", "studioId", "studioInstanceId"
        )
        if not selected_id:
            raise NativeStudioMcpError(
                "selected Studio record has no studio_id"
            )
        self.studio_id = str(selected_id)
        self._selected = selected
        return dict(selected)

    @staticmethod
    def _schema_properties(tool: dict[str, Any]) -> dict[str, Any]:
        schema = tool.get("inputSchema") or tool.get("input_schema") or {}
        if not isinstance(schema, dict):
            return {}
        properties = schema.get("properties") or {}
        return properties if isinstance(properties, dict) else {}

    def _targeted_arguments(
        self,
        tool_name: str,
        arguments: dict[str, Any],
    ) -> dict[str, Any]:
        tool = self._require_tool(tool_name)
        properties = self._schema_properties(tool)
        result = dict(arguments)
        if "studio_id" in properties:
            self.select_studio()
            result["studio_id"] = self.studio_id
        else:
            # Older Studio MCP builds did not expose studio_id. They are safe
            # only when exactly one Studio exists; otherwise targeting would
            # become implicit again.
            selected = self.select_studio()
            del selected
        return result

    def _call_official(self, tool_name: str, arguments: dict[str, Any]) -> Any:
        return self.client.call_tool(
            tool_name,
            self._targeted_arguments(tool_name, arguments),
        )

    def _keyboard_arguments(self, params: dict[str, Any]) -> dict[str, Any]:
        if isinstance(params.get("actions"), list):
            actions = list(params["actions"])
        else:
            keys = params.get("keys")
            if not isinstance(keys, list):
                key = params.get("key")
                keys = [key] if key else []
            actions = [
                {"action": "keyPress", "key_code": str(key)}
                for key in keys if key
            ]
            wait = float(params.get("duration_ms") or 0)
            if wait > 0:
                actions.append({
                    "action": "wait",
                    "wait_time_ms": min(wait, 10_000),
                })
        return {"actions": actions, "datamodel_type": "Client"}

    def _mouse_arguments(self, params: dict[str, Any]) -> dict[str, Any]:
        if isinstance(params.get("actions"), list):
            actions = list(params["actions"])
        else:
            action = str(params.get("action") or "click")
            mapped = {
                "click": "mouseButtonClick",
                "move": "moveTo",
                "down": "mouseButtonDown",
                "up": "mouseButtonUp",
                "scroll_up": "scrollUp",
                "scroll_down": "scrollDown",
                "wait": "wait",
            }.get(action)
            if mapped is None:
                raise NativeStudioMcpError(
                    f"unsupported canonical mouse action: {action}"
                )
            step: dict[str, Any] = {"action": mapped}
            if "x" in params:
                step["x"] = params["x"]
            if "y" in params:
                step["y"] = params["y"]
            if params.get("target"):
                step["instance_path"] = params["target"]
            if mapped in {"mouseButtonClick", "mouseButtonDown", "mouseButtonUp"}:
                step["mouse_button"] = str(params.get("button") or "left")
            if mapped == "wait":
                step["wait_time_ms"] = min(
                    float(params.get("duration_ms") or 0), 10_000
                )
            actions = [step]
        return {"actions": actions, "datamodel_type": "Client"}

    @staticmethod
    def _tree_records(value: Any) -> list[dict[str, Any]]:
        records: list[dict[str, Any]] = []

        def visit(node: Any) -> None:
            if isinstance(node, dict):
                name = node.get("name")
                full_path = node.get("fullPath") or node.get("path")
                if isinstance(name, str) and isinstance(full_path, str):
                    records.append(node)
                else:
                    for child in node.values():
                        visit(child)
            elif isinstance(node, list):
                for child in node:
                    visit(child)

        visit(value)
        return records

    def _resolve_semantic_target(self, target: str) -> str:
        self._require_tool("search_game_tree")
        result = self._call_official(
            "search_game_tree",
            {
                "keywords": target,
                "max_depth": 10,
                "head_limit": 200,
            },
        )
        exact = [
            item for item in self._tree_records(result)
            if str(item.get("name") or "").casefold() == target.casefold()
        ]
        paths = sorted({
            str(item.get("fullPath") or item.get("path"))
            for item in exact
            if item.get("fullPath") or item.get("path")
        })
        if len(paths) == 1:
            return paths[0]
        if not paths:
            raise NativeStudioMcpError(
                f"semantic navigation target {target!r} was not found "
                "by Studio MCP search_game_tree"
            )
        raise NativeStudioMcpError(
            f"semantic navigation target {target!r} is ambiguous: {paths}"
        )

    def _navigation_arguments(self, params: dict[str, Any]) -> dict[str, Any]:
        target = params.get("target")
        args: dict[str, Any] = {"datamodel_type": "Client"}
        if isinstance(target, (list, tuple)) and len(target) == 3:
            args.update(x=target[0], y=target[1], z=target[2])
        elif isinstance(target, str) and (
            target.startswith("game.")
            or target.startswith("Workspace.")
            or target.startswith("LocalPlayer.")
        ):
            args["instance_path"] = target
        elif isinstance(target, str) and target.strip():
            args["instance_path"] = self._resolve_semantic_target(target.strip())
        elif all(key in params for key in ("x", "y", "z")):
            args.update(x=params["x"], y=params["y"], z=params["z"])
        else:
            raise NativeStudioMcpError(
                "official character_navigation requires a target instance "
                "or x/y/z coordinates"
            )
        if params.get("speed_multiplier") is not None:
            args["speed_multiplier"] = params["speed_multiplier"]
        return args

    def _screen_arguments(self, params: dict[str, Any]) -> dict[str, Any]:
        self._capture_sequence += 1
        args: dict[str, Any] = {
            "capture_id": str(
                params.get("capture_id")
                or f"rqe_capture_{self._capture_sequence:06d}"
            )
        }
        position = params.get("camera_position") or params.get("position")
        look_at = params.get("look_at_position") or params.get("lookAt")
        if position is not None:
            args["camera_position"] = position
        if look_at is not None:
            args["look_at_position"] = look_at
        return args

    def call(self, method: str, params: dict[str, Any] | None = None) -> Any:
        params = dict(params or {})
        tool_name = self.TOOL_ALIASES.get(method, method)
        self._require_tool(tool_name)

        if method == "playtest_start":
            arguments = {"is_start": True}
            if params.get("mode") is not None:
                arguments["mode"] = params["mode"]
        elif method == "playtest_stop":
            arguments = {"is_start": False}
        elif method == "screen_capture":
            arguments = self._screen_arguments(params)
        elif method == "console_read":
            arguments = {}
        elif method == "character_navigation":
            arguments = self._navigation_arguments(params)
        elif method == "user_keyboard_input":
            arguments = self._keyboard_arguments(params)
        elif method == "user_mouse_input":
            arguments = self._mouse_arguments(params)
        else:
            arguments = params

        # Keep only arguments accepted by the live tool schema, except for
        # schemas that explicitly allow arbitrary properties.
        tool = self._require_tool(tool_name)
        schema = tool.get("inputSchema") or tool.get("input_schema") or {}
        if isinstance(schema, dict) and schema.get("additionalProperties") is False:
            allowed = set(self._schema_properties(tool))
            arguments = {
                key: value for key, value in arguments.items()
                if key in allowed
            }

        return self._call_official(tool_name, arguments)

    @staticmethod
    def _image_block(value: Any) -> dict[str, Any] | None:
        if isinstance(value, dict):
            kind = str(value.get("type") or "").casefold()
            data = value.get("data")
            if kind == "image" and isinstance(data, str):
                return value
            for child in value.values():
                found = RobloxStudioMcpTransport._image_block(child)
                if found is not None:
                    return found
        elif isinstance(value, list):
            for child in value:
                found = RobloxStudioMcpTransport._image_block(child)
                if found is not None:
                    return found
        return None

    def capture_to_file(
        self,
        output: Path | str,
        params: dict[str, Any] | None = None,
    ) -> dict[str, Any]:
        """Persist one official Studio MCP screenshot without desktop capture."""
        result = self.call("screen_capture", params or {})
        block = self._image_block(result)
        if block is None:
            raise NativeStudioMcpError(
                "Studio MCP screen_capture returned no image content"
            )

        encoded = block.get("data")
        assert isinstance(encoded, str)
        try:
            raw = base64.b64decode(encoded, validate=True)
        except (binascii.Error, ValueError) as exc:
            raise NativeStudioMcpError(
                "Studio MCP screen_capture returned invalid base64 image data"
            ) from exc
        if not raw or len(raw) > MAX_RPC_RESPONSE_BYTES:
            raise NativeStudioMcpError(
                "Studio MCP screenshot bytes are empty or exceed the RQE limit"
            )

        mime = str(
            block.get("mimeType")
            or block.get("mime_type")
            or "image/png"
        ).casefold()
        suffix = {
            "image/png": ".png",
            "image/jpeg": ".jpg",
            "image/jpg": ".jpg",
            "image/webp": ".webp",
        }.get(mime)
        if suffix is None:
            raise NativeStudioMcpError(
                f"unsupported Studio MCP screenshot mime type: {mime}"
            )

        destination = Path(output)
        if destination.suffix.casefold() != suffix:
            destination = destination.with_suffix(suffix)
        destination.parent.mkdir(parents=True, exist_ok=True)
        temporary = destination.with_name(
            f".{destination.name}.{os.getpid()}.tmp"
        )
        temporary.write_bytes(raw)
        os.replace(temporary, destination)

        return {
            "path": str(destination),
            "bytes": len(raw),
            "sha256": hashlib.sha256(raw).hexdigest(),
            "mimeType": mime,
            "studioId": self.studio_id,
            "source": "RobloxStudioMCP.screen_capture",
        }

    def capabilities(self) -> dict[str, Any]:
        tools = sorted(self._tool_map())
        selected = self.select_studio()
        return {
            "transport": "roblox-studio-mcp",
            "official": True,
            "studio": selected,
            "studioId": self.studio_id,
            "tools": tools,
            "canonicalMethods": sorted(
                method for method, tool in self.TOOL_ALIASES.items()
                if tool in self._tool_map()
            ),
        }

    def close(self) -> None:
        self.client.close()


class FederatedStudioTransport:
    """Use official Studio MCP where it is authoritative; RQE for extensions."""

    def __init__(
        self,
        official: RpcTransport,
        extension: RpcTransport,
        *,
        official_methods: frozenset[str] = OFFICIAL_CANONICAL_METHODS,
        allow_extension_fallback: bool = False,
    ) -> None:
        self.official = official
        self.extension = extension
        self.official_methods = official_methods
        self.allow_extension_fallback = allow_extension_fallback

    def call(self, method: str, params: dict[str, Any] | None = None) -> Any:
        if method not in self.official_methods:
            return self.extension.call(method, params)
        try:
            return self.official.call(method, params)
        except NativeStudioToolUnavailable:
            if not self.allow_extension_fallback:
                raise
            return self.extension.call(method, params)
