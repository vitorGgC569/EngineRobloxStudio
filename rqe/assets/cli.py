"""Command-line entry points for asset discovery and publication."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
from typing import Any

from .models import AssetKind, AssetState, PipelineOutcome, SearchQuery
from .operations import AssetOperations
from .providers.roblox import RobloxOpenCloudConfig, RobloxOpenCloudProvider


DEFAULT_ASSET_WORKSPACE = "artifacts/assets"


def add_assets_parser(subparsers: argparse._SubParsersAction) -> None:
    assets = subparsers.add_parser(
        "assets",
        help="discover, validate, publish, moderate, and integrate Roblox assets",
    )
    commands = assets.add_subparsers(dest="assets_command", required=True)

    capabilities = commands.add_parser(
        "capabilities", help="show honest provider capability and credential status"
    )
    _workspace_argument(capabilities)

    search = commands.add_parser(
        "search", help="search Roblox Creator Store and retain metadata/previews"
    )
    search.add_argument("query")
    search.add_argument(
        "--kind",
        action="append",
        choices=[kind.value for kind in AssetKind],
        help="repeat to select one or more logical asset kinds",
    )
    search.add_argument("--creator-id")
    search.add_argument("--limit", type=int, default=25)
    search.add_argument("--page-token")
    _workspace_argument(search)

    prepare = commands.add_parser(
        "prepare",
        help="validate a local/generated asset and create an immutable upload package",
    )
    prepare.add_argument("request", help="asset-work-request.v1 JSON")
    _workspace_argument(prepare)

    publish = commands.add_parser(
        "publish",
        help="dispatch one confirmed content-addressed package to Roblox Open Cloud",
    )
    publish.add_argument("package", help="immutable asset publication package JSON")
    publish.add_argument(
        "--confirm-external-effect",
        metavar="PACKAGE_ID",
        help="must exactly equal packageId before the external upload is attempted",
    )
    _workspace_argument(publish)

    status = commands.add_parser(
        "status", help="poll publication/moderation without repeating the upload"
    )
    status.add_argument("package", help="immutable asset publication package JSON")
    _workspace_argument(status)

    manifest = commands.add_parser(
        "manifest",
        help="validate production asset evidence and emit an integration bundle",
    )
    manifest.add_argument("manifest", help="asset manifest JSON")
    _workspace_argument(manifest)


def run_assets_command(args: argparse.Namespace) -> tuple[int, dict[str, Any]]:
    workspace = Path(args.workspace).resolve()
    operations = AssetOperations(_provider_from_environment(), workspace)

    if args.assets_command == "capabilities":
        return 0, operations.capabilities()

    if args.assets_command == "search":
        query = SearchQuery(
            text=args.query,
            kinds=tuple(AssetKind(value) for value in (args.kind or [])),
            creator_id=args.creator_id,
            limit=args.limit,
            page_token=args.page_token,
        )
        receipt = operations.search(query)
        receipt_path = operations.record_receipt("discovery", receipt)
        payload = {**receipt, "receiptPath": str(receipt_path)}
        outcome = receipt["result"]["outcome"]
        return (0 if outcome == PipelineOutcome.PROGRESSED.value else 1), payload

    if args.assets_command == "prepare":
        prepared, paths = operations.prepare_file(Path(args.request))
        payload = {
            **prepared.to_dict(),
            "artifactPaths": {name: str(path) for name, path in paths.items()},
        }
        return (
            0 if prepared.outcome == PipelineOutcome.PROGRESSED else 1,
            payload,
        )

    if args.assets_command == "publish":
        result = operations.publish(
            Path(args.package), confirmation=args.confirm_external_effect
        )
        # A successful dispatch is progress, not approval.  The JSON state is
        # deliberately the authority; callers must run `status` until approved.
        return (
            0 if result.outcome == PipelineOutcome.PROGRESSED else 1,
            result.to_dict(),
        )

    if args.assets_command == "status":
        result = operations.refresh(Path(args.package))
        return (
            0 if result.asset.state == AssetState.APPROVED else 1,
            result.to_dict(),
        )

    if args.assets_command == "manifest":
        report, bundle = operations.validate_manifest(Path(args.manifest))
        payload: dict[str, Any] = {"report": report.to_dict()}
        if bundle is not None:
            bundle_payload = bundle.to_dict()
            path = operations.record_receipt("integration", bundle_payload)
            payload["integrationBundle"] = bundle_payload
            payload["integrationBundlePath"] = str(path)
        return (0 if report.production_ready else 1), payload

    return 2, {"error": f"unknown assets command: {args.assets_command}"}


def render_payload(payload: dict[str, Any]) -> str:
    return json.dumps(payload, indent=2, sort_keys=True, ensure_ascii=False)


def _workspace_argument(parser: argparse.ArgumentParser) -> None:
    parser.add_argument(
        "--workspace",
        default=DEFAULT_ASSET_WORKSPACE,
        help="content-addressed asset artifact root; no global latest file is used",
    )


def _provider_from_environment() -> RobloxOpenCloudProvider:
    return RobloxOpenCloudProvider(
        RobloxOpenCloudConfig(
            api_key=os.environ.get("RQE_ROBLOX_OPEN_CLOUD_API_KEY"),
            oauth_token=os.environ.get("RQE_ROBLOX_OAUTH_TOKEN"),
        )
    )
