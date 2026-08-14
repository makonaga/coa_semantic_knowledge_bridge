# /// script
# requires-python = ">=3.12"
# dependencies = ["mcp>=1.9.0,<2.0.0"]
# ///
"""COA MCP サーバー(AgentCore Runtime)の検証用クライアント。

前提の環境変数:
  MCP_URL       — AgentCore Runtime の invocations URL
  TOKEN         — Cognito ID トークン(有効期限 約1時間)
  NAMESPACE_ID  — 省略時は change-mgmt の ID

使い方(リポジトリルートで):
  uv run scripts/mcp/coa_mcp_client.py list
  uv run scripts/mcp/coa_mcp_client.py metrics
  uv run scripts/mcp/coa_mcp_client.py rag "質問文"
  uv run scripts/mcp/coa_mcp_client.py query "質問文"
  uv run scripts/mcp/coa_mcp_client.py query --tier 3 "質問文"
"""

import argparse
import asyncio
import json
import os
import sys

from mcp import ClientSession
from mcp.client.streamable_http import streamablehttp_client

DEFAULT_NAMESPACE = "7c1ba4c7-39c6-414e-be5e-307208a01b34"  # change-mgmt


def _print_result(result) -> None:
    for item in result.content:
        text = getattr(item, "text", None)
        if text is None:
            print(item)
            continue
        try:
            print(json.dumps(json.loads(text), ensure_ascii=False, indent=2))
        except (json.JSONDecodeError, TypeError):
            print(text)


async def main() -> None:
    parser = argparse.ArgumentParser(description="COA MCP client")
    parser.add_argument("command", choices=["list", "metrics", "schema", "rag", "query"])
    parser.add_argument("text", nargs="?", help="質問文(rag / query で必須)")
    parser.add_argument("--tier", type=int, default=None, help="query の tierOverride (1/2/3)")
    parser.add_argument("--top-k", type=int, default=5, help="rag の取得チャンク数")
    args = parser.parse_args()

    url = os.environ.get("MCP_URL")
    token = os.environ.get("TOKEN")
    namespace = os.environ.get("NAMESPACE_ID", DEFAULT_NAMESPACE)
    if not url or not token:
        sys.exit("環境変数 MCP_URL と TOKEN を設定してください(手順書参照)")
    if args.command in ("rag", "query") and not args.text:
        sys.exit(f"{args.command} には質問文が必要です")

    headers = {"Authorization": f"Bearer {token}"}
    async with streamablehttp_client(url, headers=headers, timeout=120) as (read, write, _):
        async with ClientSession(read, write) as session:
            await session.initialize()

            if args.command == "list":
                tools = await session.list_tools()
                print(f"ツール数: {len(tools.tools)}")
                for t in tools.tools:
                    desc = (t.description or "").strip().splitlines()[0] if t.description else ""
                    print(f"  - {t.name}: {desc}")
                return

            if args.command == "metrics":
                result = await session.call_tool("list_metrics", {"namespace_id": namespace})
            elif args.command == "schema":
                result = await session.call_tool("describe_schema", {"namespace_id": namespace})
            elif args.command == "rag":
                result = await session.call_tool(
                    "rag_retrieval",
                    {"text": args.text, "namespace_id": namespace, "top_k": args.top_k},
                )
            else:  # query
                tool_args = {"text": args.text, "namespace_id": namespace}
                if args.tier is not None:
                    tool_args["tier_override"] = args.tier
                result = await session.call_tool("query", tool_args)

            _print_result(result)


if __name__ == "__main__":
    asyncio.run(main())
