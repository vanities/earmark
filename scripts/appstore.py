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

VERSION = "0.2.0"
LOCALE = "en-US"
SITE = "https://am2.biz/earmark"

COPY = {
    "subtitle": "MP3, M4B & offline listening",
    "promotionalText": "Your audiobook collection, ready for the next chapter. Listen from Files or your NAS, save books for offline trips, and make every book feel at home.",
    "description": """Your audiobooks. Your files. Your place in the story.

Earmark brings your MP3s, M4Bs and other audio files into a personal audiobook library. Listen from folders in Files or iCloud Drive, stream from your NAS, or download books for offline listening. No account, subscription or ads.

SETTLE INTO A GOOD BOOK
• Adjust playback from 0.5x to 3x with natural pitch and a speed remembered for each book.
• Jump between chapters, skip back or forward, and save bookmarks.
• Fall asleep with a timer, including an end-of-chapter option.
• Pick up the thread with smart rewind after a pause.
• Control playback from the lock screen and CarPlay's Now Playing screen.
• Save listening presets for the way you like to listen.

A SHELF THAT MAKES SENSE
Browse by author, series or folder, and search your collection. Earmark uses file tags and folder names to group tracks into books, including multi-disc folders. Find duplicates, adjust book groupings, and put tracks in the right order. Save smart lists and see new arrivals without losing your place.

AT HOME OR ON THE ROAD
Connect an SMB share to browse your NAS alongside local books. Stream while your server is reachable, or prepare books for an offline trip. Reconnect a moved library and back up your library state to keep your organization and listening progress safe.

YOUR COLLECTION STAYS YOURS
Playing a book leaves its audio files where they are. Downloads, moves into Earmark and uploads to your NAS happen only when you request them. Bring your own audiobooks; no catalog or books are included.

Free and open source. No analytics, donation prompts or rating nags.
Source code: github.com/vanities/earmark

Supported audio: MP3, M4A, M4B, AAC, WAV, AIFF, CAF and FLAC.""",
    "keywords": "player,nas,smb,carplay,chapters,sleep,timer,bookmarks,speed,folders,library,flac,wav,aac",
    "whatsNew": """More ways to make your library your own:
• Prepare books for offline trips.
• Reconnect moved libraries and back up your library state.
• Save smart lists and browse new arrivals.
• Combine, split and reorder book groupings, with undo.
• Save and apply listening presets.

Also fixes a crash after a NAS network timeout.""",
    "copyright": "2026 AM2 LLC",
    "supportUrl": f"{SITE}/support",
    "marketingUrl": SITE,
    "privacyPolicyUrl": f"{SITE}/privacy",
}

AGE_RATING = {
    # Content descriptors: NONE / INFREQUENT_OR_MILD / FREQUENT_OR_INTENSE
    "alcoholTobaccoOrDrugUseOrReferences": "NONE",
    "contests": "NONE",
    "gamblingSimulated": "NONE",
    "gunsOrOtherWeapons": "NONE",
    "healthOrWellnessTopics": False,
    "horrorOrFearThemes": "NONE",
    "matureOrSuggestiveThemes": "NONE",
    "medicalOrTreatmentInformation": "NONE",
    "profanityOrCrudeHumor": "NONE",
    "sexualContentGraphicAndNudity": "NONE",
    "sexualContentOrNudity": "NONE",
    "violenceCartoonOrFantasy": "NONE",
    "violenceRealistic": "NONE",
    "violenceRealisticProlongedGraphicOrSadistic": "NONE",
    # Capabilities: booleans
    "advertising": False,
    "gambling": False,
    "lootBox": False,
    "messagingAndChat": False,
    "parentalControls": False,
    "socialMedia": False,
    "socialMediaAgeRestricted": False,
    "unrestrictedWebAccess": False,
    "userGeneratedContent": False,
    "ageAssurance": False,
    "ageRatingOverride": "NONE",
    "koreaAgeRatingOverride": "NONE",
}

REVIEW_NOTES = """Earmark is an audiobook player for the user's MP3, M4B and other supported audio files. No account or sign-in is required.

This build addresses the empty-library/no-playback issue reported on September 23 for build 26. The library now detects files added to the app's folder while running, refreshes local sources when returning from Files, and correctly scans and plays individual files opened with Earmark. On iPad, an opened file is handled by the active window.

To test on a physical iPhone or iPad:
1. In Files, copy an MP3 or M4B into On My iPhone > Earmark or On My iPad > Earmark.
2. Return to Earmark. The book appears in Library. Tap it and press Play.
3. Alternatively, use Library > More (...) > Add Folder to select a folder containing audio, or Files > Open With > Earmark to open a single audio file.
4. While audio is playing, navigate to the Home Screen. Playback continues and the system's Now Playing controls remain available. Background audio is a core audiobook-listening feature and is intentionally declared in UIBackgroundModes.

Speed, chapters, sleep timer and skip controls are in the player. Sources can optionally connect to the reviewer's SMB server; a NAS is not required. The app has no developer-operated backend."""


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


def set_review_details(asc: Store, version_id: str, phone: str) -> None:
    detail = asc.get(f"/v1/appStoreVersions/{version_id}/appStoreReviewDetail").get("data")
    review_attrs = {"contactFirstName": "Adam", "contactLastName": "Mischke", "contactEmail": "mischke@proton.me", "contactPhone": phone, "demoAccountRequired": False, "notes": REVIEW_NOTES}
    if detail:
        report("review contact + notes", asc.patch_ok(f"/v1/appStoreReviewDetails/{detail['id']}", {"data": {"type": "appStoreReviewDetails", "id": detail["id"], "attributes": review_attrs}}))
    else:
        report("review contact + notes", asc.post_ok("/v1/appStoreReviewDetails", {"data": {"type": "appStoreReviewDetails", "attributes": review_attrs, "relationships": {"appStoreVersion": {"data": {"type": "appStoreVersions", "id": version_id}}}}}))


def cmd_setup(asc: Store, phone: str | None) -> None:
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
        result = asc.patch_ok(f"/v1/appStoreVersionLocalizations/{loc['id']}", {"data": {"type": "appStoreVersionLocalizations", "id": loc["id"], "attributes": attrs}})
        if "_status" in result and "whatsNew" in result["_text"]:
            attrs.pop("whatsNew")  # not editable on an app's first version
            result = asc.patch_ok(f"/v1/appStoreVersionLocalizations/{loc['id']}", {"data": {"type": "appStoreVersionLocalizations", "id": loc["id"], "attributes": attrs}})
        report(f"version {version['attributes']['versionString']} copy (description, keywords, URLs)", result)
        report(f"version {VERSION}: manual release, copyright", asc.patch_ok(f"/v1/appStoreVersions/{version['id']}", {"data": {"type": "appStoreVersions", "id": version["id"], "attributes": {"versionString": VERSION, "releaseType": "MANUAL", "copyright": COPY["copyright"]}}}))

        if phone:
            set_review_details(asc, version["id"], phone)
        else:
            print("  - review contact skipped: pass --phone '+1 555 555 5555' (App Review requires a phone number)")

    # Price: free, USA as base territory.
    if asc.get(f"/v1/apps/{app_id}/appPriceSchedule").get("data"):
        print("  = price schedule already set")
        return
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
    for info in asc.get(f"/v1/apps/{app['id']}/appInfos", {"fields[appInfos]": "state,appStoreState,primaryCategory,secondaryCategory", "include": "primaryCategory,secondaryCategory"})["data"]:
        rel = info.get("relationships", {})
        primary = (rel.get("primaryCategory", {}).get("data") or {}).get("id")
        secondary = (rel.get("secondaryCategory", {}).get("data") or {}).get("id")
        print(f"  appInfo state={info['attributes'].get('state') or info['attributes'].get('appStoreState')} categories={primary}/{secondary}")
        for loc in asc.get(f"/v1/appInfos/{info['id']}/appInfoLocalizations", {"fields[appInfoLocalizations]": "locale,name,subtitle,privacyPolicyUrl"})["data"]:
            a = loc["attributes"]; print(f"    {a['locale']}: name={a.get('name')!r} subtitle={a.get('subtitle')!r} privacy={a.get('privacyPolicyUrl')}")
    for version in asc.get(f"/v1/apps/{app['id']}/appStoreVersions", {"filter[platform]": "IOS", "limit": 5, "fields[appStoreVersions]": "versionString,appVersionState,releaseType,build", "include": "build", "fields[builds]": "version"})["data"]:
        a = version["attributes"]
        build_id = (version.get("relationships", {}).get("build", {}).get("data") or {}).get("id")
        build = asc.get(f"/v1/builds/{build_id}", {"fields[builds]": "version"})["data"]["attributes"]["version"] if build_id else None
        detail = asc.get(f"/v1/appStoreVersions/{version['id']}/appStoreReviewDetail", {"fields[appStoreReviewDetails]": "contactPhone"}).get("data")
        print(f"  version {a['versionString']} state={a.get('appVersionState')} release={a.get('releaseType')} build={build or 'none'} reviewContact={'set' if detail and detail['attributes'].get('contactPhone') else 'missing phone'}")
        for loc in asc.get(f"/v1/appStoreVersions/{version['id']}/appStoreVersionLocalizations", {"fields[appStoreVersionLocalizations]": "locale,keywords,supportUrl,marketingUrl"})["data"]:
            a = loc["attributes"]; print(f"    {a['locale']}: keywords={a.get('keywords')!r} support={a.get('supportUrl')} marketing={a.get('marketingUrl')}")
            sets = asc.get(f"/v1/appStoreVersionLocalizations/{loc['id']}/appScreenshotSets", {"fields[appScreenshotSets]": "screenshotDisplayType"})["data"]
            for shot_set in sets:
                shots = asc.get(f"/v1/appScreenshotSets/{shot_set['id']}/appScreenshots", {"fields[appScreenshots]": "fileName,assetDeliveryState", "limit": 20})["data"]
                states = [s["attributes"]["assetDeliveryState"]["state"] for s in shots]
                print(f"    screenshots {shot_set['attributes']['screenshotDisplayType']}: {len(shots)} ({', '.join(sorted(set(states)))})")


def cmd_submit(asc: Store, dry_run: bool) -> None:
    """Submit the editable version via reviewSubmissions: find/create → add item → submitted=true."""
    app = asc.app() or sys.exit("no app record")
    version = editable_version(asc, app["id"], create=False) or sys.exit("no editable version")
    attached = (asc.get(f"/v1/appStoreVersions/{version['id']}", {"fields[appStoreVersions]": "versionString", "include": "build", "fields[builds]": "version"}).get("included") or [{}])[0].get("attributes", {}).get("version")
    print(f"version {version['attributes']['versionString']} build {attached or 'NONE'}")
    if not attached:
        sys.exit("no build attached; run attach-build first")
    if dry_run:
        print("dry run: not submitting"); return
    existing = asc.get(f"/v1/apps/{app['id']}/reviewSubmissions", {"filter[platform]": "IOS", "filter[state]": "READY_FOR_REVIEW"})["data"]
    if existing:
        submission = existing[0]
        print(f"  reusing submission {submission['id']}")
    else:
        submission = asc.post("/v1/reviewSubmissions", {"data": {"type": "reviewSubmissions", "attributes": {"platform": "IOS"}, "relationships": {"app": {"data": {"type": "apps", "id": app["id"]}}}}})["data"]
        print(f"  ✓ created submission {submission['id']}")
    items = asc.get(f"/v1/reviewSubmissions/{submission['id']}/items", {"limit": 10}).get("data", [])
    if not items:
        asc.post("/v1/reviewSubmissionItems", {"data": {"type": "reviewSubmissionItems", "relationships": {
            "reviewSubmission": {"data": {"type": "reviewSubmissions", "id": submission["id"]}},
            "appStoreVersion": {"data": {"type": "appStoreVersions", "id": version["id"]}},
        }}})
        print(f"  ✓ added version {version['attributes']['versionString']} to the submission")
    result = asc.patch_ok(f"/v1/reviewSubmissions/{submission['id']}", {"data": {"type": "reviewSubmissions", "id": submission["id"], "attributes": {"submitted": True}}})
    report("submitted for review", result)


def cmd_submission_status(asc: Store) -> None:
    app = asc.app() or sys.exit("no app record")
    for submission in asc.get(f"/v1/apps/{app['id']}/reviewSubmissions", {"filter[platform]": "IOS", "fields[reviewSubmissions]": "state,submittedDate", "limit": 5})["data"]:
        a = submission["attributes"]
        print(f"  submission {submission['id'][:8]}… state={a['state']} submitted={str(a.get('submittedDate'))[:19]}")
        for item in asc.get(f"/v1/reviewSubmissions/{submission['id']}/items", {"fields[reviewSubmissionItems]": "state", "limit": 10}).get("data", []):
            print(f"    item state={item['attributes']['state']}")
    for version in asc.get(f"/v1/apps/{app['id']}/appStoreVersions", {"filter[platform]": "IOS", "limit": 3, "fields[appStoreVersions]": "versionString,appVersionState"})["data"]:
        print(f"  version {version['attributes']['versionString']}: {version['attributes'].get('appVersionState')}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    setup = sub.add_parser("setup"); setup.add_argument("--phone", help="App Review contact phone, e.g. '+1 555 555 5555'")
    review = sub.add_parser("review"); review.add_argument("--phone", required=True)
    shots = sub.add_parser("screenshots"); shots.add_argument("directory")
    attach = sub.add_parser("attach-build"); attach.add_argument("build", nargs="?")
    sub.add_parser("status")
    submit = sub.add_parser("submit"); submit.add_argument("--dry-run", action="store_true")
    sub.add_parser("submission-status")
    args = parser.parse_args()
    asc = Store(tf.load_env())
    match args.command:
        case "setup": cmd_setup(asc, args.phone)
        case "review":
            app = asc.app() or sys.exit("no app record")
            version = editable_version(asc, app["id"], create=False) or sys.exit("no editable version")
            set_review_details(asc, version["id"], args.phone)
        case "screenshots": cmd_screenshots(asc, Path(args.directory))
        case "attach-build": cmd_attach_build(asc, args.build)
        case "status": cmd_status(asc)
        case "submit": cmd_submit(asc, args.dry_run)
        case "submission-status": cmd_submission_status(asc)


if __name__ == "__main__":
    main()
