"""Seed an environment (local or ephemeral PR env) with synthetic patients.

Synthetic only: names and emails are generated, never sampled from real data.
Used by `make seed` locally and by the ephemeral-env workflow after deploy.

    python scripts/seed_synthetic.py --url http://localhost:8000 --count 200
"""

from __future__ import annotations

import argparse
import json
import random
import urllib.request
from datetime import date, timedelta

FIRST = ["Avery", "Jordan", "Riley", "Casey", "Morgan", "Quinn", "Rowan", "Sage", "Emerson", "Hayden"]
LAST = ["Testwell", "Synthetica", "Placeholder", "Mockford", "Fakeley", "Sampleton"]
ZIPS = ["02139", "10001", "60601", "94105", "03601", "89301"]  # includes restricted zip3s (036, 893)


def make(i: int, rng: random.Random) -> dict:
    first, last = rng.choice(FIRST), rng.choice(LAST)
    dob = date(1925, 1, 1) + timedelta(days=rng.randint(0, 36000))
    return {
        "external_ref": f"synthetic-{i:06d}",
        "name": f"{first} {last}",
        "date_of_birth": dob.isoformat(),
        "email": f"{first.lower()}.{last.lower()}.{i}@example.com",
        "zip_code": rng.choice(ZIPS),
    }


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", default="http://localhost:8000")
    ap.add_argument("--count", type=int, default=100)
    ap.add_argument("--seed", type=int, default=42)
    args = ap.parse_args()
    rng = random.Random(args.seed)
    for i in range(args.count):
        req = urllib.request.Request(
            f"{args.url}/v1/patients",
            data=json.dumps(make(i, rng)).encode(),
            headers={"content-type": "application/json", "x-actor": "svc:seeder"},
            method="POST",
        )
        urllib.request.urlopen(req, timeout=10).read()
    print(f"seeded {args.count} synthetic patients into {args.url}")


if __name__ == "__main__":
    main()
