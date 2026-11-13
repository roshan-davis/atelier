#!/usr/bin/env python3
"""Regenerates Docs/agent-actions-catalog.json from the action registry (AT-050).

The catalog is written by AtelierActionsTests, so it always matches the Swift declarations.
`swift test` (and so Scripts/check_pr.py) fails while the committed file is stale.

    python3 Scripts/agent_catalog.py          # rewrite the file
    python3 Scripts/agent_catalog.py --check  # only check it
"""
import argparse
import os
from pathlib import Path
import subprocess
import sys

TEST = "AtelierActionsTests.AtelierActionsTests/testCommittedCatalogIsCurrent"


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--check", action="store_true", help="Fail if the committed catalog is stale")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    env = os.environ.copy()
    if not args.check:
        env["ATELIER_WRITE_AGENT_CATALOG"] = "1"
    swift = ["xcrun", "swift"] if sys.platform == "darwin" else ["swift"]
    code = subprocess.call(swift + ["test", "--filter", TEST], cwd=root, env=env)
    if code == 0 and not args.check:
        print("Wrote Docs/agent-actions-catalog.json. Commit it, and say in the PR which agent commands changed.")
    return code


if __name__ == "__main__":
    sys.exit(main())
