# /// script
# requires-python = ">=3.11"
# dependencies = ["PyJWT>=2.8", "cryptography>=42", "requests>=2.31"]
# ///
"""Fill in the App Store listing for Earmark via the App Store Connect API.

Idempotent: safe to re-run. Reads credentials like scripts/testflight.py.

  uv run --script scripts/appstore.py setup                 # categories, age rating, rights, URLs, version + copy, price, review info
  uv run --script scripts/appstore.py screenshots DIR       # upload 1290x2796 PNGs from DIR as the 6.7" iPhone set
  uv run --script scripts/appstore.py attach-build [N]      # bind a processed TestFlight build (default: newest) to the version
  uv run --script scripts/appstore.py status                # print what App Store Connect has
"""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import sys
from pathlib import Path

import requests

ROOT = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("tf", ROOT / "testflight.py")
tf = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tf)  # type: ignore[union-attr]

VERSION = "0.1.0"
LOCALE = "en-US"
SITE = "https://am2.biz/earmark"

COPY = {
    "subtitle": "Your audiobooks, your files",
    "promotionalText": "Plays the audiobooks you already have, right where they are. No accounts, no ads, no tip jar.",
    "description": """Earmark is an audiobook player for people with folders full of MP3s and M4Bs.

PLAYS YOUR FILES WHERE THEY ARE
Point Earmark at a folder in Files, iCloud Drive, or another app and it plays from there. Nothing is copied, nothing is moved, nothing is uploaded. Your library stays yours.

ORGANIZED AUTOMATICALLY
A folder of MP3s is a book, every M4B is a book with its chapters, Disc 1 and Disc 2 folders merge, and Author / Series / Book folder names or tags fill in the rest. Browse by author, series, or folder, or search everything.

FIND DUPLICATES
Every file is fingerprinted by content, so the same book sitting in two places is found even when the names differ. Nothing is deleted without asking.

A PLAYER BUILT FOR LONG BOOKS
• 0.5x to 3x speed with natural pitch, remembered per book
• Chapters, 15 and 30 second skips, sleep timer with end-of-chapter
• Smart rewind: back up a few seconds after a pause so you catch the thread
• Lock screen and CarPlay Now Playing controls

YOUR NAS, ON YOUR SHELF
Add an SMB share and its books appear alongside local ones with a Remote badge. Stream while you are on your home network, download a book to keep it on your phone, or Sync from NAS to fetch everything you do not have yet. If the server is unreachable, Earmark says so.

NO TIP JAR
No accounts, no analytics, no ads, no donation screens. Earmark is free and open source (GPL-3.0). Read the code at github.com/vanities/earmark.

Supported formats: MP3, M4A, M4B, AAC, WAV, AIFF, CAF, FLAC.""",
    "keywords": "audiobook,audiobooks,player,mp3,m4b,nas,smb,carplay,chapters,folders,offline,library,speed",
    "whatsNew": "First release.",
    "supportUrl": f"{SITE}/support",
    "marketingUrl": SITE,
    "privacyPolicyUrl": f"{SITE}/privacy",
}

AGE_RATING = {
    "alcoholTobaccoOrDrugUseOrReferences": "NONE",
    "contests": "NONE",
    "gambling": False,
    "gamblingSimulated": "NONE",
    "horrorOrFearThemes": "NONE",
    "matureOrSuggestiveThemes": "NONE",
    "medicalOrTreatmentInformation": "NONE",
    "profanityOrCrudeHumor": "NONE",
    "sexualContentGraphicAndNudity": "NONE",
    "sexualContentOrNudity": "NONE",
    "unrestrictedWebAccess": False,
    "violenceCartoonOrFantasy": "NONE",
    "violenceRealistic": "NONE",
    "violenceRealisticProlongedGraphicOrSadistic": "NONE",
}

REVIEW_NOTES = """Earmark is a local audiobook player. It has no accounts.

To test: on the device, open the Files app and copy any MP3 or M4B files into On My iPhone > Earmark, or tap + in the Library tab and pick any folder containing audio. Books appear on the shelf; tap one and press Play. Speed, chapters, sleep timer, and skips are in the player.

The NAS feature (Folders > Add NAS…) connects to the user's own SMB server on their local network; it is optional and can be skipped during review. The app never contacts servers operated by us."""


class Store(tf.ASC):
    def patch_ok(self, path: str, body: dict) -> dict:
        response = requests.patch(f"{tf.API}{path}", headers=self._headers(), json=body, timeout=30)
        return response.json() if response.ok and response.text else {"_status": response.status_code, "_text": response.text}

    def post_ok(self, path: str, body: dict) -> dict:
        response = requests.post(f"{tf.API}{path}", headers=self._headers(), json=body, timeout=30)
        return response.json() if response.ok and response.text else {"_status": response.status_code, "_text": response.text}


def report(label: str, result: dict) -> None:
    if "_status" in result:
        print(f"  ✗ {label}: {result['_status']} {result['_text'][:240]}")
    else:
        print(f"  ✓ {label}")


def editable_version(asc: Store, app_id: str, create: bool) -> dict | None:
    versions = asc.get(f"/v1/apps/{app_id}/appStoreVersions", {"filter[platform]": "IOS", "limit": 10, "fields[appStoreVersions]": "versionString,appStoreState,appVersionState,releaseType"})["data"]
    editable_states = {"PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED", "REJECTED", "METADATA_REJECTED", "WAITING_FOR_REVIEW", "INVALID_BINARY"}
    for version in versions:
        state = version["attributes"].get("appVersionState") or version["attributes"].get("appStoreState")
        if state in editable_states:
            return version
    if not create:
        return None
    created = asc.post("/v1/appStoreVersions", {"data": {"type": "appStoreVersions", "attributes": {"platform": "IOS", "versionString": VERSION, "releaseType": "MANUAL"}, "relationships": {"app": {"data": {"type": "apps", "id": app_id}}}}})
    print(f"  ✓ created version {VERSION} (manual release)")
    return created["data"]


def version_localization(asc: Store, version_id: str) -> dict:
    locs = asc.get(f"/v1/appStoreVersions/{version_id}/appStoreVersionLocalizations", {"fields[appStoreVersionLocalizations]": "locale"})["data"]
    for loc in locs:
        if loc["attributes"]["locale"] == LOCALE:
            return loc
    return asc.post("/v1/appStoreVersionLocalizations", {"data": {"type": "appStoreVersionLocalizations", "attributes": {"locale": LOCALE}, "relationships": {"appStoreVersion": {"data": {"type": "appStoreVersions", "id": version_id}}}}})["data"]


def cmd_setup(asc: Store) -> None:
    app = asc.app() or sys.exit("no app record")
    app_id = app["id"]
    print(f"{app['attributes']['name']} ({app_id})")

    report("content rights: no third-party content", asc.patch_ok(f"/v1/apps/{app_id}", {"data": {"type": "apps", "id": app_id, "attributes": {"contentRightsDeclaration": "DOES_NOT_USE_THIRD_PARTY_CONTENT"}}}))

    infos = asc.get(f"/v1/apps/{app_id}/appInfos", {"fields[appInfos]": "appStoreState,state"})["data"]
    info = next((i for i in infos if (i["attributes"].get("state") or i["attributes"].get("appStoreState")) not in ("READY_FOR_SALE", "READY_FOR_DISTRIBUTION")), infos[0])
    report("categories: Books / Utilities", asc.patch_ok(f"/v1/appInfos/{info['id']}", {"data": {"type": "appInfos", "id": info["id"], "relationships": {
        "primaryCategory": {"data": {"type": "appCategories", "id": "BOOKS"}},
        "secondaryCategory": {"data": {"type": "appCategories", "id": "UTILITIES"}},
    }}}))

    rating = asc.get(f"/v1/appInfos/{info['id']}/ageRatingDeclaration").get("data")
    if rating:
        report("age rating: 4+ (nothing to declare)", asc.patch_ok(f"/v1/ageRatingDeclarations/{rating['id']}", {"data": {"type": "ageRatingDeclarations", "id": rating["id"], "attributes": AGE_RATING}}))

    for loc in asc.get(f"/v1/appInfos/{info['id']}/appInfoLocalizations", {"fields[appInfoLocalizations]": "locale"})["data"]:
        report(f"app info {loc['attributes']['locale']}: subtitle + privacy URL", asc.patch_ok(f"/v1/appInfoLocalizations/{loc['id']}", {"data": {"type": "appInfoLocalizations", "id": loc["id"], "attributes": {"subtitle": COPY["subtitle"], "privacyPolicyUrl": COPY["privacyPolicyUrl"]}}}))

    version = editable_version(asc, app_id, create=True)
    if version:
        loc = version_localization(asc, version["id"])
        attrs = {k: COPY[k] for k in ("description", "keywords", "promotionalText", "whatsNew", "supportUrl", "marketingUrl")}
        report(f"version {version['attributes']['versionString']} copy (description, keywords, URLs)", asc.patch_ok(f"/v1/appStoreVersionLocalizations/{loc['id']}", {"data": {"type": "appStoreVersionLocalizations", "id": loc["id"], "attributes": attrs}}))

        detail = asc.get(f"/v1/appStoreVersions/{version['id']}/appStoreReviewDetail").get("data")
        review_attrs = {"contactFirstName": "Adam", "contactLastName": "Mischke", "contactEmail": "mischke@proton.me", "demoAccountRequired": False, "notes": REVIEW_NOTES}
        if detail:
            report("review contact + notes", asc.patch_ok(f"/v1/appStoreReviewDetails/{detail['id']}", {"data": {"type": "appStoreReviewDetails", "id": detail["id"], "attributes": review_attrs}}))
        else:
            report("review contact + notes", asc.post_ok("/v1/appStoreReviewDetails", {"data": {"type": "appStoreReviewDetails", "attributes": review_attrs, "relationships": {"appStoreVersion": {"data": {"type": "appStoreVersions", "id": version["id"]}}}}}))

    # Price: free, USA as base territory.
    points = asc.get(f"/v1/apps/{app_id}/appPricePoints", {"filter[territory]": "USA", "fields[appPricePoints]": "customerPrice,proceeds", "limit": 200})["data"]
    free = next((p for p in points if float(p["attributes"]["customerPrice"]) == 0.0), None)
    if free:
        result = asc.post_ok("/v1/appPriceSchedules", {
            "data": {"type": "appPriceSchedules", "relationships": {
                "app": {"data": {"type": "apps", "id": app_id}},
                "baseTerritory": {"data": {"type": "territories", "id": "USA"}},
                "manualPrices": {"data": [{"type": "appPrices", "id": "${price-free}"}]},
            }},
            "included": [{"type": "appPrices", "id": "${price-free}", "attributes": {"startDate": None}, "relationships": {"appPricePoint": {"data": {"type": "appPricePoints", "id": free["id"]}}}}],
        })
        report("price: Free (all territories)", result)
    else:
        print("  ✗ price: could not find the free price point")

    print("\nStill manual in App Store Connect: App Privacy → 'Data Not Collected' (Get Started → No → Publish),")
    print("and the review contact phone number under Version → App Review Information.")


def cmd_screenshots(asc: Store, directory: Path) -> None:
    app = asc.app() or sys.exit("no app record")
    version = editable_version(asc, app["id"], create=False) or sys.exit("no editable version; run setup first")
    loc = version_localization(asc, version["id"])
    sets = asc.get(f"/v1/appStoreVersionLocalizations/{loc['id']}/appScreenshotSets", {"fields[appScreenshotSets]": "screenshotDisplayType"})["data"]
    display_type = "APP_IPHONE_67"
    shot_set = next((s for s in sets if s["attributes"]["screenshotDisplayType"] == display_type), None)
    if not shot_set:
        shot_set = asc.post("/v1/appScreenshotSets", {"data": {"type": "appScreenshotSets", "attributes": {"screenshotDisplayType": display_type}, "relationships": {"appStoreVersionLocalization": {"data": {"type": "appStoreVersionLocalizations", "id": loc["id"]}}}}})["data"]
        print(f"created screenshot set {display_type}")
    existing = asc.get(f"/v1/appScreenshotSets/{shot_set['id']}/appScreenshots", {"fields[appScreenshots]": "fileName,assetDeliveryState", "limit": 20})["data"]
    existing_names = {e["attributes"]["fileName"] for e in existing}
    files = sorted(p for p in directory.iterdir() if p.suffix.lower() == ".png")
    for path in files[:10]:
        if path.name in existing_names:
            print(f"  = {path.name} already uploaded")
            continue
        data = path.read_bytes()
        reservation = asc.post("/v1/appScreenshots", {"data": {"type": "appScreenshots", "attributes": {"fileName": path.name, "fileSize": len(data)}, "relationships": {"appScreenshotSet": {"data": {"type": "appScreenshotSets", "id": shot_set["id"]}}}}})["data"]
        for op in reservation["attributes"]["uploadOperations"]:
            chunk = data[op["offset"]: op["offset"] + op["length"]]
            headers = {h["name"]: h["value"] for h in op["requestHeaders"]}
            response = requests.request(op["method"], op["url"], headers=headers, data=chunk, timeout=120)
            response.raise_for_status()
        asc.patch(f"/v1/appScreenshots/{reservation['id']}", {"data": {"type": "appScreenshots", "id": reservation["id"], "attributes": {"uploaded": True, "sourceFileChecksum": hashlib.md5(data).hexdigest()}}})
        print(f"  ✓ uploaded {path.name} ({len(data) // 1024} KB)")


def cmd_attach_build(asc: Store, build_number: str | None) -> None:
    app = asc.app() or sys.exit("no app record")
    version = editable_version(asc, app["id"], create=False) or sys.exit("no editable version; run setup first")
    builds = asc.builds(app["id"], limit=25)
    target = next((b for b in builds if (build_number is None or b["attributes"]["version"] == build_number) and b["attributes"]["processingState"] == "VALID"), None) or sys.exit("no processed build found")
    asc.patch(f"/v1/appStoreVersions/{version['id']}/relationships/build", {"data": {"type": "builds", "id": target["id"]}})
    print(f"  ✓ attached build {target['attributes']['version']} to version {version['attributes']['versionString']}")


def cmd_status(asc: Store) -> None:
    app = asc.app() or sys.exit("no app record")
    print(f"{app['attributes']['name']} ({app['attributes']['bundleId']}) rights={app['attributes'].get('contentRightsDeclaration')}")
    for info in asc.get(f"/v1/apps/{app['id']}/appInfos", {"fields[appInfos]": "state,appStoreState", "include": "primaryCategory,secondaryCategory"})["data"]:
        rel = info.get("relationships", {})
        print(f"  appInfo state={info['attributes'].get('state') or info['attributes'].get('appStoreState')} primary={rel.get('primaryCategory', {}).get('data', {}) and rel['primaryCategory']['data'].get('id')} secondary={rel.get('secondaryCategory', {}).get('data', {}) and rel['secondaryCategory']['data'].get('id')}")
        for loc in asc.get(f"/v1/appInfos/{info['id']}/appInfoLocalizations", {"fields[appInfoLocalizations]": "locale,name,subtitle,privacyPolicyUrl"})["data"]:
            a = loc["attributes"]; print(f"    {a['locale']}: name={a.get('name')!r} subtitle={a.get('subtitle')!r} privacy={a.get('privacyPolicyUrl')}")
    for version in asc.get(f"/v1/apps/{app['id']}/appStoreVersions", {"filter[platform]": "IOS", "limit": 5, "fields[appStoreVersions]": "versionString,appVersionState,releaseType", "include": "build"})["data"]:
        a = version["attributes"]
        build = (version.get("relationships", {}).get("build", {}).get("data") or {}).get("id")
        print(f"  version {a['versionString']} state={a.get('appVersionState')} release={a.get('releaseType')} build={'attached' if build else 'none'}")
        for loc in asc.get(f"/v1/appStoreVersions/{version['id']}/appStoreVersionLocalizations", {"fields[appStoreVersionLocalizations]": "locale,keywords,supportUrl,marketingUrl"})["data"]:
            a = loc["attributes"]; print(f"    {a['locale']}: keywords={a.get('keywords')!r} support={a.get('supportUrl')} marketing={a.get('marketingUrl')}")
            sets = asc.get(f"/v1/appStoreVersionLocalizations/{loc['id']}/appScreenshotSets", {"fields[appScreenshotSets]": "screenshotDisplayType"})["data"]
            for shot_set in sets:
                shots = asc.get(f"/v1/appScreenshotSets/{shot_set['id']}/appScreenshots", {"fields[appScreenshots]": "fileName,assetDeliveryState", "limit": 20})["data"]
                states = [s["attributes"]["assetDeliveryState"]["state"] for s in shots]
                print(f"    screenshots {shot_set['attributes']['screenshotDisplayType']}: {len(shots)} ({', '.join(sorted(set(states)))})")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("setup")
    shots = sub.add_parser("screenshots"); shots.add_argument("directory")
    attach = sub.add_parser("attach-build"); attach.add_argument("build", nargs="?")
    sub.add_parser("status")
    args = parser.parse_args()
    asc = Store(tf.load_env())
    match args.command:
        case "setup": cmd_setup(asc)
        case "screenshots": cmd_screenshots(asc, Path(args.directory))
        case "attach-build": cmd_attach_build(asc, args.build)
        case "status": cmd_status(asc)


if __name__ == "__main__":
    main()
