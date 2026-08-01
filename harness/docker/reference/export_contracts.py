#!/usr/bin/env python3
"""Credential-free reference export entrypoint for deterministic contract vectors.

This tool never imports the SDK or starts Claude. Its phase-3 vectors are narrow,
redacted JSON inputs transcribed from the pinned upstream test scenarios and
written with the source node/symbol provenance required by the target manifest.
"""
from __future__ import annotations

import argparse
import json
import shutil
from pathlib import Path

COMMIT = "3145cc637778b23cb3caff7556ab76a10028b084"

VECTORS = {
    "types/assistant-message-unknown-field.json": {
        "source": {"upstream_commit": COMMIT, "pytest_node": "tests/test_message_parser.py::TestMessageParser::test_parse_valid_assistant_message", "symbol": "claude_agent_sdk._internal.message_parser.parse_message"},
        "wire": {"type": "assistant", "message": {"model": "claude-sonnet-4-5", "content": [{"type": "text", "text": "Hello"}]}, "futureField": {"enabled": True}},
    },
    "options/options-wire.json": {
        "source": {"upstream_commit": COMMIT, "pytest_node": "tests/test_types.py::TestOptions::test_claude_code_options_with_tools", "symbol": "claude_agent_sdk.types.ClaudeAgentOptions"},
        "options": {"allowedTools": ["Read", "Write"], "disallowedTools": ["Bash"], "permissionMode": "acceptEdits", "continue": True, "model": "claude-sonnet-4-5"},
    },
    "conditions/typed-errors.json": {
        "source": {"upstream_commit": COMMIT, "pytest_node": "tests/test_errors.py::TestErrorTypes::test_process_error", "symbol": "claude_agent_sdk._errors.ProcessError"},
        "process_error": {"message": "claude exited", "exit_code": 17, "stderr": "bad stderr"}, "malformed_json_line": "{broken",
    },
}


def export_sdk_mcp_tools() -> dict[str, object]:
    """Run the pinned upstream in-process MCP path and normalize its wire contract.

    This deliberately projects only the tools-only v1 subset that the target
    supports. It does not fabricate provider output or external MCP transports.
    """
    import asyncio
    from claude_agent_sdk import create_sdk_mcp_server, tool
    from mcp.types import CallToolRequest, CallToolRequestParams, ListToolsRequest

    @tool(
        "echo",
        "Echo back the input text",
        {"type": "object", "properties": {"text": {"type": "string"}}, "required": ["text"]},
    )
    async def echo(arguments: dict[str, object]) -> dict[str, object]:
        return {"content": [{"type": "text", "text": f"Echo: {arguments['text']}"}]}

    config = create_sdk_mcp_server(name="test", version="1.0.0", tools=[echo])
    server = config["instance"]

    async def invoke() -> tuple[object, object]:
        listed = await server.request_handlers[ListToolsRequest](ListToolsRequest(method="tools/list"))
        called = await server.request_handlers[CallToolRequest](
            CallToolRequest(
                method="tools/call",
                params=CallToolRequestParams(name="echo", arguments={"text": "value"}),
            )
        )
        return listed, called

    listed, called = asyncio.run(invoke())
    listed_tool = listed.root.tools[0]
    called_item = called.root.content[0]
    if config["type"] != "sdk" or config["name"] != "test":
        raise RuntimeError("upstream SDK MCP server configuration changed")
    if listed_tool.name != "echo" or listed_tool.description != "Echo back the input text":
        raise RuntimeError("upstream SDK MCP tools/list contract changed")
    if called_item.type != "text" or called_item.text != "Echo: value":
        raise RuntimeError("upstream SDK MCP tools/call contract changed")
    return {
        "source": {
            "upstream_commit": COMMIT,
            "pytest_node": "tests/test_sdk_mcp_integration.py::test_sdk_mcp_server_handlers",
            "symbol": "claude_agent_sdk.create_sdk_mcp_server",
        },
        "server_config": {"type": config["type"], "name": config["name"]},
        "qualified_tool_name": "mcp__test__echo",
        "tool": {
            "name": listed_tool.name,
            "description": listed_tool.description,
            "inputSchema": (listed_tool.inputSchema.model_dump()
                            if hasattr(listed_tool.inputSchema, "model_dump")
                            else listed_tool.inputSchema),
        },
        "call_result": {"content": [{"type": called_item.type, "text": called_item.text}]},
    }


def verify_upstream_message_parser() -> None:
    """Execute one pinned upstream behavior before exporting its target vector."""
    from claude_agent_sdk._internal.message_parser import parse_message
    from claude_agent_sdk.types import AssistantMessage, TextBlock

    wire = VECTORS["types/assistant-message-unknown-field.json"]["wire"]
    parsed = parse_message(wire)
    if not isinstance(parsed, AssistantMessage):
        raise RuntimeError(f"expected AssistantMessage, got {type(parsed)!r}")
    if not isinstance(parsed.content[0], TextBlock) or parsed.content[0].text != "Hello":
        raise RuntimeError("upstream parser did not preserve the expected text block")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("catalog", nargs="?", type=Path)
    parser.add_argument("output", nargs="?", type=Path)
    parser.add_argument("--phase3-fixtures", type=Path, help="write phase-3 vectors under this directory")
    args = parser.parse_args()
    if args.phase3_fixtures:
        verify_upstream_message_parser()
        vectors = dict(VECTORS)
        # Keep the async upstream MCP execution out of module import and normal
        # catalog-copy paths; this deterministic export is explicit and offline.
        vectors["mcp/sdk-mcp-tools.json"] = export_sdk_mcp_tools()
        for relative, payload in vectors.items():
            output = args.phase3_fixtures / relative
            output.parent.mkdir(parents=True, exist_ok=True)
            output.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
        return
    if not args.catalog or not args.output:
        parser.error("catalog and output are required unless --phase3-fixtures is used")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(args.catalog, args.output)


if __name__ == "__main__":
    main()
