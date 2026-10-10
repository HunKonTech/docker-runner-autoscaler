#!/usr/bin/env python3
"""Create a Buffer (X) post for a newly published GitHub release."""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import urllib.error
import urllib.request
from typing import Any

API_URL = "https://api.buffer.com"
MAX_POST_LENGTH = 280
_URL_RE = re.compile(r"https?://\S+")
_X_URL_LENGTH = 23  # X shortens every URL to a t.co link of this length
HASHTAGS = "#GitHubActions #Docker #DevOps #SelfHosted"
DEFAULT_TEMPLATE = (
    "{app_name} {tag} is out.\n\n"
    "Ephemeral GitHub Actions runners in Docker Desktop on Windows. "
    "Scales with your job queue, never stops a busy runner and updates itself.\n\n"
    "{release_url}\n"
    f"{HASHTAGS}"
)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app-name", default="Docker Runner Autoscaler", help="Display name of the app.")
    parser.add_argument("--tag", required=True, help="Release tag, for example v1.0.12.")
    parser.add_argument("--release-url", required=True, help="Public URL of the GitHub release.")
    parser.add_argument(
        "--template",
        default=os.environ.get("BUFFER_POST_TEMPLATE", ""),
        help="Optional custom template. Supported placeholders: {app_name}, {tag}, {version}, {release_url}.",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Print the generated post and selected mode without sending it to Buffer.",
    )
    args = parser.parse_args()

    api_key = os.environ.get("BUFFER_API_KEY", "").strip()
    if not api_key and not args.dry_run:
        print("Skipping Buffer post: set BUFFER_API_KEY to enable release announcements.", file=sys.stderr)
        return 0

    post_text = build_release_post_text(
        app_name=args.app_name,
        tag=args.tag,
        release_url=args.release_url,
        template=args.template or None,
    )
    mode = validate_mode((os.environ.get("BUFFER_POST_MODE") or "").strip() or "shareNow")

    if args.dry_run:
        print(post_text)
        print(f"mode={mode} length={_x_weighted_length(post_text)}", file=sys.stderr)
        return 0

    client = BufferClient(api_key=api_key)
    channel = select_target_channel(
        client=client,
        organization_id=os.environ.get("BUFFER_ORGANIZATION_ID", "").strip() or None,
        channel_id=os.environ.get("BUFFER_CHANNEL_ID", "").strip() or None,
        channel_name=os.environ.get("BUFFER_CHANNEL_NAME", "").strip() or None,
        channel_service=os.environ.get("BUFFER_CHANNEL_SERVICE", "twitter").strip() or "twitter",
    )

    result = client.create_post(channel_id=channel["id"], text=post_text, mode=mode)
    due_at = result.get("dueAt")
    channel_label = channel.get("displayName") or channel.get("name") or channel["id"]
    if due_at:
        print(f"Created Buffer release post for {channel_label}; due at {due_at}.")
    else:
        print(f"Created Buffer release post for {channel_label}.")
    return 0


def build_release_post_text(
    *,
    app_name: str,
    tag: str,
    release_url: str,
    template: str | None = None,
) -> str:
    version = tag[1:] if tag.startswith("v") else tag
    context = {
        "app_name": app_name,
        "tag": tag,
        "version": version,
        "release_url": release_url,
    }

    if template:
        text = template.format(**context).strip()
        ensure_post_length(text)
        return text

    variants = [
        DEFAULT_TEMPLATE.format(**context).strip(),
        DEFAULT_TEMPLATE.replace(f"\n{HASHTAGS}", "").format(**context).strip(),
        (
            "{app_name} {tag} is out.\n\n"
            "Autoscaling GitHub Actions runners in Docker Desktop on Windows.\n\n"
            "{release_url}"
        ).format(**context).strip(),
    ]
    for variant in variants:
        if _x_weighted_length(variant) <= MAX_POST_LENGTH:
            return variant

    compact = "{app_name} {tag} is out: {release_url}".format(**context)
    ensure_post_length(compact)
    return compact


def _x_weighted_length(text: str) -> int:
    # X shortens every URL to a fixed-length t.co link, and counts characters
    # outside the Basic Multilingual Plane (most emoji) as weight 2.
    normalized = _URL_RE.sub("x" * _X_URL_LENGTH, text)
    return sum(2 if ord(ch) > 0xFFFF else 1 for ch in normalized)


def ensure_post_length(text: str) -> None:
    length = _x_weighted_length(text)
    if length > MAX_POST_LENGTH:
        raise ValueError(f"Generated Buffer post is too long ({length} weighted characters).")


def validate_mode(value: str) -> str:
    if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", value):
        raise SystemExit(f"Invalid BUFFER_POST_MODE value: {value!r}")
    return value


def select_target_channel(
    *,
    client: "BufferClient",
    organization_id: str | None,
    channel_id: str | None,
    channel_name: str | None,
    channel_service: str,
) -> dict[str, Any]:
    if channel_id:
        return {
            "id": channel_id,
            "name": channel_name or channel_id,
            "displayName": channel_name or channel_id,
            "service": channel_service,
        }

    org_ids = [organization_id] if organization_id else client.get_organization_ids()
    candidates: list[dict[str, Any]] = []
    for org_id in org_ids:
        for channel in client.get_channels(org_id):
            if channel.get("service", "").casefold() != channel_service.casefold():
                continue
            candidates.append(channel)

    if channel_name:
        needle = channel_name.casefold()
        named = [
            channel
            for channel in candidates
            if needle in (channel.get("name") or "").casefold()
            or needle in (channel.get("displayName") or "").casefold()
        ]
        if not named:
            raise SystemExit(
                f"No Buffer channel matched BUFFER_CHANNEL_NAME={channel_name!r} "
                f"for service {channel_service!r}."
            )
        candidates = named

    if not candidates:
        raise SystemExit(
            "No matching Buffer channel found. Set BUFFER_CHANNEL_ID or connect an X/Twitter "
            "channel in Buffer."
        )

    candidates.sort(
        key=lambda channel: (
            str(channel.get("displayName") or ""),
            str(channel.get("name") or ""),
            str(channel.get("id") or ""),
        )
    )
    if len(candidates) > 1:
        selected = candidates[0]
        label = selected.get("displayName") or selected.get("name") or selected["id"]
        print(
            f"Multiple Buffer channels matched; using {label}. "
            "Set BUFFER_CHANNEL_ID or BUFFER_CHANNEL_NAME to make this explicit.",
            file=sys.stderr,
        )
        return selected
    return candidates[0]


class BufferClient:
    def __init__(self, *, api_key: str) -> None:
        self._headers = {
            "Content-Type": "application/json",
            "Authorization": f"Bearer {api_key}",
            "User-Agent": "docker-runner-autoscaler-release-bot",
        }

    def get_organization_ids(self) -> list[str]:
        data = self._graphql(
            """
            query GetOrganizations {
              account {
                organizations {
                  id
                }
              }
            }
            """
        )
        organizations = data["account"]["organizations"]
        return [item["id"] for item in organizations]

    def get_channels(self, organization_id: str) -> list[dict[str, Any]]:
        data = self._graphql(
            """
            query GetChannels($organizationId: OrganizationId!) {
              channels(input: { organizationId: $organizationId }) {
                id
                name
                displayName
                service
                isQueuePaused
              }
            }
            """,
            variables={"organizationId": organization_id},
        )
        return data["channels"]

    def create_post(self, *, channel_id: str, text: str, mode: str) -> dict[str, Any]:
        data = self._graphql(
            f"""
            mutation CreateReleasePost($channelId: ChannelId!, $text: String!) {{
              createPost(input: {{
                text: $text,
                channelId: $channelId,
                schedulingType: automatic,
                mode: {mode}
              }}) {{
                __typename
                ... on PostActionSuccess {{
                  post {{
                    id
                    text
                    dueAt
                  }}
                }}
                ... on MutationError {{
                  message
                }}
              }}
            }}
            """,
            variables={"channelId": channel_id, "text": text},
        )
        result = data["createPost"]
        typename = result.get("__typename")
        if typename == "MutationError":
            raise SystemExit(f"Buffer rejected the release post: {result.get('message', 'Unknown error')}")
        if typename != "PostActionSuccess":
            raise SystemExit(f"Unexpected Buffer createPost response: {result}")
        return result["post"]

    def _graphql(self, query: str, variables: dict[str, Any] | None = None) -> dict[str, Any]:
        payload = {"query": query, "variables": variables or {}}
        request = urllib.request.Request(
            url=API_URL,
            data=json.dumps(payload).encode("utf-8"),
            method="POST",
            headers=self._headers,
        )
        try:
            with urllib.request.urlopen(request) as response:
                raw = response.read()
        except urllib.error.HTTPError as exc:
            body = exc.read().decode("utf-8", errors="replace")
            raise SystemExit(f"Buffer API request failed ({exc.code}): {body}") from exc

        response_data = json.loads(raw.decode("utf-8"))
        if response_data.get("errors"):
            messages = ", ".join(error.get("message", "Unknown GraphQL error") for error in response_data["errors"])
            raise SystemExit(f"Buffer GraphQL error: {messages}")
        return response_data["data"]


if __name__ == "__main__":
    raise SystemExit(main())
