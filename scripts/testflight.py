# /// script
# requires-python = ">=3.11"
# dependencies = ["PyJWT>=2.8", "cryptography>=42", "requests>=2.31"]
# ///
"""TestFlight helper for Earmark via the App Store Connect API.

Reads .env.appstore-connect (APPSTORE_CONNECT_KEY_ID / _ISSUER_ID / _KEY_FILE / _BUNDLE_ID)
from the repo root, or the same names from the environment.

  uv run --script scripts/testflight.py status            # app, latest builds, processing state
  uv run --script scripts/testflight.py groups            # beta groups and their testers
  uv run --script scripts/testflight.py ensure-group      # create an internal group that gets every build
  uv run --script scripts/testflight.py wait [--minutes 20]   # block until the newest build finishes processing
  uv run --script scripts/testflight.py notes "What to test…" [--build 12]
"""
from __future__ import annotations

import argparse
import os
import sys
import time
from pathlib import Path

import jwt
import requests

API = "https://api.appstoreconnect.apple.com"
ROOT = Path(__file__).resolve().parent.parent


def load_env() -> dict[str, str]:
    env: dict[str, str] = {}
    env_file = ROOT / ".env.appstore-connect"
    if env_file.exists():
        for line in env_file.read_text().splitlines():
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                key, _, value = line.partition("=")
                env[key.strip()] = value.strip()
    for key in ("APPSTORE_CONNECT_KEY_ID", "APPSTORE_CONNECT_ISSUER_ID", "APPSTORE_CONNECT_KEY_FILE", "APPSTORE_CONNECT_BUNDLE_ID"):
        env.setdefault(key, os.environ.get(key, ""))
        if not env[key]:
            sys.exit(f"missing {key}; see .env.appstore-connect.example")
    return env


class ASC:
    def __init__(self, env: dict[str, str]):
        key_path = Path(env["APPSTORE_CONNECT_KEY_FILE"])
        if not key_path.is_absolute():
            key_path = ROOT / key_path
        if not key_path.exists():
            sys.exit(f"private key not found at {key_path}")
        now = int(time.time())
        self.token = jwt.encode(
            {"iss": env["APPSTORE_CONNECT_ISSUER_ID"], "iat": now, "exp": now + 1200, "aud": "appstoreconnect-v1"},
            key_path.read_text(),
            algorithm="ES256",
            headers={"kid": env["APPSTORE_CONNECT_KEY_ID"], "typ": "JWT"},
        )
        self.bundle_id = env["APPSTORE_CONNECT_BUNDLE_ID"]

    def _headers(self) -> dict[str, str]:
        return {"Authorization": f"Bearer {self.token}", "Content-Type": "application/json"}

    def get(self, path: str, params: dict | None = None) -> dict:
        response = requests.get(f"{API}{path}", headers=self._headers(), params=params, timeout=30)
        if not response.ok:
            sys.exit(f"GET {path} → {response.status_code}\n{response.text}")
        return response.json()

    def post(self, path: str, body: dict) -> dict:
        response = requests.post(f"{API}{path}", headers=self._headers(), json=body, timeout=30)
        if not response.ok:
            sys.exit(f"POST {path} → {response.status_code}\n{response.text}")
        return response.json() if response.text else {}

    def patch(self, path: str, body: dict) -> dict:
        response = requests.patch(f"{API}{path}", headers=self._headers(), json=body, timeout=30)
        if not response.ok:
            sys.exit(f"PATCH {path} → {response.status_code}\n{response.text}")
        return response.json() if response.text else {}

    def app(self) -> dict | None:
        data = self.get("/v1/apps", {"filter[bundleId]": self.bundle_id, "limit": 1})["data"]
        return data[0] if data else None

    def builds(self, app_id: str, limit: int = 10) -> list[dict]:
        return self.get("/v1/builds", {"filter[app]": app_id, "sort": "-uploadedDate", "limit": limit, "fields[builds]": "version,uploadedDate,processingState,expired,usesNonExemptEncryption"})["data"]

    def groups(self, app_id: str) -> list[dict]:
        return self.get(f"/v1/apps/{app_id}/betaGroups", {"fields[betaGroups]": "name,isInternalGroup,hasAccessToAllBuilds,publicLinkEnabled,publicLink"})["data"]


def cmd_status(asc: ASC) -> None:
    app = asc.app()
    if not app:
        print(f"No App Store Connect app for {asc.bundle_id} yet.")
        print("Create it at https://appstoreconnect.apple.com/apps → + → New App (iOS, name Earmark, this bundle ID, any SKU), then re-run.")
        return
    attrs = app["attributes"]
    print(f"{attrs['name']}  ({attrs['bundleId']})  id={app['id']}  sku={attrs.get('sku')}")
    builds = asc.builds(app["id"])
    if not builds:
        print("No builds uploaded yet. Run: make testflight")
    for build in builds:
        a = build["attributes"]
        print(f"  build {a['version']:>6}  {a['processingState']:<11} uploaded {a['uploadedDate'][:19]}  encryption={a.get('usesNonExemptEncryption')}")
    for group in asc.groups(app["id"]):
        g = group["attributes"]
        kind = "internal" if g["isInternalGroup"] else "external"
        print(f"  group '{g['name']}' ({kind}, all builds={g['hasAccessToAllBuilds']}, public link={g.get('publicLink') or 'off'})")


def cmd_groups(asc: ASC) -> None:
    app = asc.app() or sys.exit("no app record yet")
    for group in asc.groups(app["id"]):
        g = group["attributes"]
        testers = asc.get(f"/v1/betaGroups/{group['id']}/betaTesters", {"fields[betaTesters]": "email,firstName,lastName,state", "limit": 50})["data"]
        print(f"{g['name']} ({'internal' if g['isInternalGroup'] else 'external'}): {len(testers)} testers")
        for tester in testers:
            t = tester["attributes"]
            print(f"   - {t.get('firstName') or ''} {t.get('lastName') or ''} <{t.get('email')}> {t.get('state')}")


def cmd_ensure_group(asc: ASC, name: str) -> None:
    app = asc.app() or sys.exit("no app record yet")
    for group in asc.groups(app["id"]):
        if group["attributes"]["name"] == name:
            print(f"group '{name}' already exists (id={group['id']})")
            return
    created = asc.post("/v1/betaGroups", {
        "data": {
            "type": "betaGroups",
            "attributes": {"name": name, "isInternalGroup": True, "hasAccessToAllBuilds": True},
            "relationships": {"app": {"data": {"type": "apps", "id": app["id"]}}},
        }
    })
    print(f"created internal group '{name}' (id={created['data']['id']}); every new build is available to its testers automatically.")
    print("Add yourself: App Store Connect → TestFlight → Internal Testing → the group → + → pick your ASC user.")


def cmd_wait(asc: ASC, minutes: int) -> None:
    app = asc.app() or sys.exit("no app record yet")
    deadline = time.time() + minutes * 60
    while time.time() < deadline:
        builds = asc.builds(app["id"], limit=1)
        if builds:
            a = builds[0]["attributes"]
            print(f"build {a['version']}: {a['processingState']}")
            if a["processingState"] == "VALID":
                return
            if a["processingState"] in ("FAILED", "INVALID"):
                sys.exit("build processing failed — check the email from App Store Connect")
        else:
            print("no builds yet…")
        time.sleep(30)
    sys.exit("timed out waiting for processing")


def cmd_notes(asc: ASC, text: str, build_number: str | None) -> None:
    app = asc.app() or sys.exit("no app record yet")
    builds = asc.builds(app["id"], limit=25)
    target = next((b for b in builds if build_number is None or b["attributes"]["version"] == build_number), None) or sys.exit("build not found")
    localizations = asc.get(f"/v1/builds/{target['id']}/betaBuildLocalizations")["data"]
    if localizations:
        asc.patch(f"/v1/betaBuildLocalizations/{localizations[0]['id']}", {"data": {"type": "betaBuildLocalizations", "id": localizations[0]["id"], "attributes": {"whatsNew": text}}})
    else:
        asc.post("/v1/betaBuildLocalizations", {"data": {"type": "betaBuildLocalizations", "attributes": {"locale": "en-US", "whatsNew": text}, "relationships": {"build": {"data": {"type": "builds", "id": target["id"]}}}}})
    print(f"set test notes on build {target['attributes']['version']}")


def cmd_users(asc: ASC) -> None:
    for user in asc.get("/v1/users", {"fields[users]": "username,firstName,lastName,roles", "limit": 50})["data"]:
        u = user["attributes"]
        print(f"  {u.get('firstName') or ''} {u.get('lastName') or ''} <{u['username']}>  roles={','.join(u.get('roles') or [])}")


def cmd_add_tester(asc: ASC, email: str, group_name: str) -> None:
    app = asc.app() or sys.exit("no app record yet")
    group = next((g for g in asc.groups(app["id"]) if g["attributes"]["name"] == group_name), None) or sys.exit(f"group '{group_name}' not found; run ensure-group")
    existing = asc.get("/v1/betaTesters", {"filter[email]": email, "limit": 1})["data"]
    if existing:
        asc.post(f"/v1/betaGroups/{group['id']}/relationships/betaTesters", {"data": [{"type": "betaTesters", "id": existing[0]["id"]}]})
    else:
        asc.post("/v1/betaTesters", {"data": {"type": "betaTesters", "attributes": {"email": email}, "relationships": {"betaGroups": {"data": [{"type": "betaGroups", "id": group["id"]}]}}}})
    print(f"added {email} to '{group_name}'")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("status")
    sub.add_parser("groups")
    ensure = sub.add_parser("ensure-group")
    ensure.add_argument("--name", default="Internal Testers")
    wait = sub.add_parser("wait")
    wait.add_argument("--minutes", type=int, default=20)
    notes = sub.add_parser("notes")
    notes.add_argument("text")
    notes.add_argument("--build")
    sub.add_parser("users")
    add = sub.add_parser("add-tester")
    add.add_argument("--email", required=True)
    add.add_argument("--group", default="Internal Testers")
    args = parser.parse_args()

    asc = ASC(load_env())
    match args.command:
        case "status": cmd_status(asc)
        case "groups": cmd_groups(asc)
        case "ensure-group": cmd_ensure_group(asc, args.name)
        case "wait": cmd_wait(asc, args.minutes)
        case "notes": cmd_notes(asc, args.text, args.build)
        case "users": cmd_users(asc)
        case "add-tester": cmd_add_tester(asc, args.email, args.group)


if __name__ == "__main__":
    main()
