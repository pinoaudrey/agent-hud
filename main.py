#!/usr/bin/env python3
"""agenthud: the snapshot daemon behind the Clubhouse menu-bar app.

One subcommand, `serve`, which polls subscription usage and live agent activity,
folds them into a single snapshot, and serves it on loopback for the Swift app.
Everything the daemon needs is in the standard library, so this runs against a
bare `python3` with no virtualenv.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

from serve import serve


def main() -> None:
    parser = argparse.ArgumentParser(
        prog="agenthud",
        description="the resident HUD snapshot daemon",
    )
    parser.add_argument("command", choices=["serve"], help="serve: run the snapshot daemon")
    parser.add_argument(
        "--host",
        default="127.0.0.1",
        help="host to bind (default 127.0.0.1; non-loopback needs AGENTHUD_SERVE_ALLOW_REMOTE=1)",
    )
    parser.add_argument("--port", type=int, default=8737, help="port to bind (default 8737)")
    args = parser.parse_args()

    serve(host=args.host, port=args.port)


if __name__ == "__main__":
    main()
