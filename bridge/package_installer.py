#!/usr/bin/env python3
"""Synchronize source payloads and the single-file BAT. No downloaded dependencies."""

import base64
import gzip
import json
from pathlib import Path
import re
import textwrap

import patch_engine_sim as patcher


ROOT = Path(__file__).resolve().parent.parent


def encoded(text):
    return base64.b64encode(gzip.compress(text.encode("utf-8"), mtime=0)).decode("ascii")


def package():
    source = ROOT / "Install-MotorTownEngineSim.ps1"
    text = source.read_text(encoding="utf-8")
    payloads = {
        "over": patcher.OVERRIDE,
        "hdr": patcher.HEADER,
        "lua": (ROOT / "bridge/UE4SS/Mods/MotorTownEngineSim/Scripts/main.lua").read_text(encoding="utf-8"),
        "runtimePatch": json.dumps(patcher.runtime_spec(), ensure_ascii=True),
    }
    for name, value in payloads.items():
        text, count = re.subn(r"\$" + name + r" = Decode '[^']+'",
                              lambda _: "$" + name + " = Decode '" + encoded(value) + "'", text)
        if count != 1:
            raise RuntimeError(f"Expected one installer payload: {name}")
    source.write_text(text, encoding="utf-8")
    bat = ROOT / "Install-MotorTownEngineSim.bat"
    launcher = bat.read_text(encoding="utf-8").split(":MTES_PAYLOAD_BEGIN", 1)[0]
    output = launcher + ":MTES_PAYLOAD_BEGIN\n" + "\n".join(textwrap.wrap(encoded(text), 140)) + "\n"
    bat.write_bytes(output.replace("\n", "\r\n").encode("ascii"))


if __name__ == "__main__":
    package()
