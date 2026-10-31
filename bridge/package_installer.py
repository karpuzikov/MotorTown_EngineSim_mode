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

    # The diagnostic BAT is self-contained and shares game detection with setup.
    collector = ROOT / "bridge/collect_diagnostics.ps1"
    diagnostic_text = collector.read_text(encoding="utf-8")
    start = text.index("function Resolve-GameExe(")
    end = text.index("\nfunction ", start + 1)
    resolver = text[start:end].rstrip()
    diagnostic_text, count = re.subn(
        r"# MTES_GAME_DETECTION_BEGIN\n.*?# MTES_GAME_DETECTION_END",
        lambda _: "# MTES_GAME_DETECTION_BEGIN\n" + resolver + "\n# MTES_GAME_DETECTION_END",
        diagnostic_text, flags=re.DOTALL)
    if count != 1:
        raise RuntimeError("Collector game detection markers missing")
    collector.write_text(diagnostic_text, encoding="utf-8")
    diagnostic_launcher = launcher.replace(" - Installer", " - Connection Diagnostics").replace("installation failed", "diagnostics failed")
    diagnostic_bat = diagnostic_launcher + ":MTES_PAYLOAD_BEGIN\n" + "\n".join(textwrap.wrap(encoded(diagnostic_text), 140)) + "\n"
    (ROOT / "Collect-MotorTownEngineSim-Logs.bat").write_bytes(diagnostic_bat.replace("\n", "\r\n").encode("ascii"))


if __name__ == "__main__":
    package()
