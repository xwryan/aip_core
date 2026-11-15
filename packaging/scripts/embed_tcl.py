#!/usr/bin/env python3
"""Embed Tcl source files into a C header as one Tcl script payload."""

from __future__ import annotations

import argparse
import json
from pathlib import Path


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("output", type=Path)
    parser.add_argument("sources", type=Path, nargs="+")
    args = parser.parse_args()

    payload_parts = []
    for source in args.sources:
        text = source.read_text(encoding="utf-8")
        payload_parts.append(
            "# Embedded AIP Tcl source: " + source.name + "\n" + text
        )
    # Sentinel evaluated last: the UCLI API reports no Tcl errors, so the
    # extension checks this variable to know the whole payload was evaluated.
    payload = "\n\n".join(payload_parts) + "\n" + "set ::_aip_payload_ok 1\n"

    args.output.parent.mkdir(parents=True, exist_ok=True)
    literal = json.dumps(payload, ensure_ascii=False)
    args.output.write_text(
        "/* generated; do not edit */\n"
        "#ifndef AIP_TCL_PAYLOAD_H\n"
        "#define AIP_TCL_PAYLOAD_H\n"
        "static const char aip_tcl_payload[] = "
        + literal
        + ";\n"
        "#endif\n",
        encoding="utf-8",
    )


if __name__ == "__main__":
    main()
