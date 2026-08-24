#!/usr/bin/env python3
"""Print the next unused TestFlight build number for an app.

    python3 Tools/asc_build_number.py --bundle-id com.idlery.turbid

Reads credentials from the environment, never from arguments, so they cannot
appear in a process listing or a CI log:

    ASC_KEY_ID        the App Store Connect API key identifier
    ASC_ISSUER_ID     the issuer that created it
    ASC_KEY_PATH      path to the .p8 private key

Asks App Store Connect what build numbers already exist rather than assuming a
CI run number is unused. Builds uploaded by any other system — Codemagic, Xcode
from a laptop — are counted too, which is the whole point: App Store Connect
rejects a build number it has seen before under the same version, and the
rejection arrives after the upload has finished.

Takes the maximum across every version rather than only the current marketing
version. Uniqueness is required per version, so a global maximum is stricter
than it needs to be, and being stricter costs nothing but a larger integer.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.request

API = "https://api.appstoreconnect.apple.com"
AUDIENCE = "appstoreconnect-v1"
# Apple rejects a token whose lifetime exceeds 20 minutes.
TOKEN_LIFETIME_SECONDS = 15 * 60


def next_build_number(versions) -> int:
    """One more than the largest integer build number seen, or 1 if none is.

    Non-numeric build numbers (`1.0.3`, `beta2`) are ignored rather than
    guessed at: a build numbered `1.0.3` says nothing about what integer is
    free, and inventing an ordering for it would be the kind of assumption
    this script exists to avoid.
    """
    highest = 0
    for version in versions:
        text = str(version).strip()
        if text.isdigit():
            highest = max(highest, int(text))
    return highest + 1


def token(key_id: str, issuer_id: str, key_path: str) -> str:
    try:
        import jwt
    except ImportError:  # pragma: no cover - environment problem, not logic
        raise SystemExit("PyJWT is not installed: python3 -m pip install pyjwt cryptography")
    with open(key_path, "r", encoding="utf-8") as handle:
        private_key = handle.read()
    issued = int(time.time())
    return jwt.encode(
        {
            "iss": issuer_id,
            "iat": issued,
            "exp": issued + TOKEN_LIFETIME_SECONDS,
            "aud": AUDIENCE,
        },
        private_key,
        algorithm="ES256",
        headers={"kid": key_id, "typ": "JWT"},
    )


def get(url: str, bearer: str) -> dict:
    request = urllib.request.Request(url, headers={"Authorization": f"Bearer {bearer}"})
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            return json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as error:
        # The body carries Apple's reason. It never contains the key.
        detail = error.read().decode("utf-8", errors="replace")[:500]
        raise SystemExit(f"App Store Connect returned {error.code} for {url}\n{detail}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--bundle-id", required=True)
    arguments = parser.parse_args()

    missing = [name for name in ("ASC_KEY_ID", "ASC_ISSUER_ID", "ASC_KEY_PATH")
               if not os.environ.get(name)]
    if missing:
        raise SystemExit(f"missing environment: {', '.join(missing)}")

    bearer = token(os.environ["ASC_KEY_ID"],
                   os.environ["ASC_ISSUER_ID"],
                   os.environ["ASC_KEY_PATH"])

    apps = get(f"{API}/v1/apps?filter[bundleId]={arguments.bundle_id}&limit=200", bearer)
    records = apps.get("data", [])
    if not records:
        raise SystemExit(
            f"no App Store Connect app record for {arguments.bundle_id}; "
            "the record has to exist before a build can be uploaded to it"
        )
    app_id = records[0]["id"]
    print(f"app record {app_id} for {arguments.bundle_id}", file=sys.stderr)

    versions = []
    url = f"{API}/v1/builds?filter[app]={app_id}&limit=200&fields[builds]=version"
    while url:
        page = get(url, bearer)
        versions += [item["attributes"].get("version") for item in page.get("data", [])]
        url = page.get("links", {}).get("next")

    print(f"{len(versions)} existing build(s): {sorted(versions)[-5:]}", file=sys.stderr)
    print(next_build_number(versions))
    return 0


if __name__ == "__main__":
    sys.exit(main())
