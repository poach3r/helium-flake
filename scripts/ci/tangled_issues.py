#!/usr/bin/env python3
"""Open/close Tangled issues as the bot account (stdlib only).

Issues are atproto records in the bot's own repo:
  sh.tangled.repo.issue        {repo: <repo DID>, title, body, createdAt}
  sh.tangled.repo.issue.state  {issue: <at-uri>, state: ...open|...closed, createdAt}

  tangled_issues.py open  --title T [--body B]      no-op if an open bot issue has this title
  tangled_issues.py close --title-prefix P [--keep T]

Env: BOT_HANDLE, BOT_APP_PASSWORD, TANGLED_REPO_DID (set by spindle).
"""

import argparse
import json
import os
import sys
import urllib.parse
import urllib.request
from datetime import datetime, timezone

ISSUE = "sh.tangled.repo.issue"
STATE = "sh.tangled.repo.issue.state"
OPEN = "sh.tangled.repo.issue.state.open"
CLOSED = "sh.tangled.repo.issue.state.closed"


def request(url, data=None, token=None):
    headers = {"User-Agent": "helium-flake-ci"}
    if data is not None:
        headers["Content-Type"] = "application/json"
        data = json.dumps(data).encode()
    if token:
        headers["Authorization"] = f"Bearer {token}"
    with urllib.request.urlopen(urllib.request.Request(url, data, headers)) as resp:
        body = resp.read().decode()
        return json.loads(body) if body else {}


def resolve_pds(handle):
    try:
        did = urllib.request.urlopen(f"https://{handle}/.well-known/atproto-did").read().decode().strip()
    except Exception:
        did = request("https://public.api.bsky.app/xrpc/com.atproto.identity.resolveHandle?"
                      + urllib.parse.urlencode({"handle": handle}))["did"]
    doc = request(f"https://plc.directory/{did}")
    for svc in doc["service"]:
        if svc["id"].endswith("#atproto_pds"):
            return svc["serviceEndpoint"]
    sys.exit(f"no PDS found for {handle}")


def now():
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


class Bot:
    def __init__(self):
        handle = os.environ["BOT_HANDLE"]
        self.pds = resolve_pds(handle)
        session = request(f"{self.pds}/xrpc/com.atproto.server.createSession",
                          {"identifier": handle, "password": os.environ["BOT_APP_PASSWORD"]})
        self.did, self.token = session["did"], session["accessJwt"]
        self.repo = os.environ["TANGLED_REPO_DID"]

    def list(self, collection):
        records, cursor = [], None
        while True:
            params = {"repo": self.did, "collection": collection, "limit": 100}
            if cursor:
                params["cursor"] = cursor
            page = request(f"{self.pds}/xrpc/com.atproto.repo.listRecords?"
                           + urllib.parse.urlencode(params), token=self.token)
            records += page.get("records", [])
            cursor = page.get("cursor")
            if not cursor or not page.get("records"):
                return records

    def create(self, collection, record):
        record = {"$type": collection, "createdAt": now(), **record}
        return request(f"{self.pds}/xrpc/com.atproto.repo.createRecord",
                       {"repo": self.did, "collection": collection, "record": record},
                       token=self.token)["uri"]

    def open_issues(self):
        """Bot-authored issues on this repo whose latest state is open."""
        latest = {}
        for rec in self.list(STATE):
            value = rec["value"]
            prev = latest.get(value["issue"])
            if prev is None or value["createdAt"] > prev["createdAt"]:
                latest[value["issue"]] = value
        return [
            rec for rec in self.list(ISSUE)
            if rec["value"].get("repo") == self.repo
            and latest.get(rec["uri"], {}).get("state", OPEN) == OPEN
        ]


def main():
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="cmd", required=True)
    p_open = sub.add_parser("open")
    p_open.add_argument("--title", required=True)
    p_open.add_argument("--body", default="")
    p_close = sub.add_parser("close")
    p_close.add_argument("--title-prefix", required=True)
    p_close.add_argument("--keep", help="title to leave open")
    args = parser.parse_args()

    bot = Bot()
    issues = bot.open_issues()

    if args.cmd == "open":
        if any(i["value"]["title"] == args.title for i in issues):
            print(f"already open: {args.title}")
            return
        uri = bot.create(ISSUE, {"repo": bot.repo, "title": args.title, "body": args.body})
        print(f"opened {uri}: {args.title}")
    else:
        for issue in issues:
            title = issue["value"]["title"]
            if title.startswith(args.title_prefix) and title != args.keep:
                bot.create(STATE, {"issue": issue["uri"], "state": CLOSED})
                print(f"closed {issue['uri']}: {title}")


if __name__ == "__main__":
    main()
