#!/usr/bin/env python3
"""Repair known Engine Simulator core lifetime bugs in a disposable build checkout.

Use only on a separately downloaded build copy, never the player's installed
game. Unknown upstream revisions are rejected before any file is changed.
"""

import hashlib
from pathlib import Path
import sys


MARK = "// MTES_HEADLESS_CORE_LIFETIME_V1"
FILES = {
    "simulator.cpp": "3a014d5dd7e2584250db33605fc51d07d1f7779b811f92c8599d19a654831eb4",
    "piston_engine_simulator.cpp": "0da7b8fd41e2da0074e19f1ed056e56f24c512c67ac828460355c8549eec38ad",
    "compiler.cpp": "71314012594c46ee8b6151abdf8170cec88ed1cb1d5a2dcbc7bf95a17bbeed3e",
}


def transformed(name: str, source: str) -> str:
    if name == "simulator.cpp":
        before = "void Simulator::destroy() {\n    m_synthesizer.destroy();\n}"
        after = ("void Simulator::destroy() {\n"
                 "    m_synthesizer.destroy();\n"
                 "    delete[] m_dynoTorqueSamples;\n"
                 "    m_dynoTorqueSamples = nullptr;\n"
                 "    " + MARK + "\n}")
        if source.count(before) != 1:
            raise ValueError("Unsupported Simulator::destroy layout")
        return source.replace(before, after, 1)

    if name == "piston_engine_simulator.cpp":
        replacements = (
            ("    assert(m_antialiasingFilters == nullptr);\n", ""),
            ("    if (m_linkConstraints != nullptr) delete[] m_linkConstraints;\n",
             "    if (m_linkConstraints != nullptr) delete[] m_linkConstraints;\n"
             "    if (m_crankshaftLinks != nullptr) delete[] m_crankshaftLinks;\n"),
            ("    m_linkConstraints = nullptr;\n"
             "    m_crankshaftFrictionConstraints = nullptr;\n"
             "    m_exhaustFlowStagingBuffer = nullptr;",
             "    m_linkConstraints = nullptr;\n"
             "    m_crankshaftLinks = nullptr;\n"
             "    m_crankshaftFrictionConstraints = nullptr;\n"
             "    m_exhaustFlowStagingBuffer = nullptr;"),
            ("    m_delayFilters = nullptr;\n}\n\nvoid PistonEngineSimulator::writeToSynthesizer()",
             "    m_delayFilters = nullptr;\n    Simulator::destroy();\n"
             "    " + MARK + "\n}\n\nvoid PistonEngineSimulator::writeToSynthesizer()"),
        )
        for old, new in replacements:
            if source.count(old) != 1:
                raise ValueError("Unsupported PistonEngineSimulator layout: " + old.strip())
            source = source.replace(old, new, 1)
        return source

    if name == "compiler.cpp":
        old = '#include "../include/compiler.h"\n'
        new = old + "#include <cstdlib>\n"
        if source.count(old) != 1:
            raise ValueError("Unsupported Compiler includes")
        source = source.replace(old, new, 1)
        old = ("    std::ofstream file(\"error_log.log\", std::ios::out);\n"
               "    piranha::IrCompilationUnit *unit = m_compiler->compile(path);")
        new = ("    // Resolve engine definitions relative to the profile, not Motor Town's cwd.\n"
               "    piranha::IrPath scriptDirectory;\n"
               "    path.getParentPath(&scriptDirectory);\n"
               "    piranha::IrPath scriptLibrary = scriptDirectory.append(\"../es/\");\n"
               "    m_compiler->addSearchPath(scriptLibrary.toString());\n"
               "    // Never create an error_log.log in the game's installation folder.\n"
               "    std::ofstream file;\n"
               "    if (const char *logPath = std::getenv(\"MTES_SCRIPT_LOG_PATH\")) {\n"
               "        if (*logPath) file.open(logPath, std::ios::out);\n"
               "    }\n"
               "    " + MARK + "\n"
               "    piranha::IrCompilationUnit *unit = m_compiler->compile(path);")
        if source.count(old) != 1:
            raise ValueError("Unsupported Compiler::compile layout")
        return source.replace(old, new, 1)

    raise ValueError("Unsupported source file " + name)


def patch(root: Path) -> None:
    root = Path(root).resolve()
    updates = {}
    existing = 0
    for name, expected_hash in FILES.items():
        path = root / ("scripting/src" if name == "compiler.cpp" else "src") / name
        raw = path.read_bytes()
        source = raw.decode("utf-8").replace("\r\n", "\n")
        if MARK in source:
            existing += 1
            continue
        if hashlib.sha256(source.encode("utf-8")).hexdigest() != expected_hash:
            raise ValueError("Unknown Engine Simulator revision: " + name)
        replacement = transformed(name, source)
        newline = "\r\n" if b"\r\n" in raw else "\n"
        updates[path] = replacement.replace("\n", newline).encode("utf-8")
    if existing and updates:
        raise ValueError("Partially patched Engine Simulator checkout; source untouched")
    for path, data in updates.items():
        path.write_bytes(data)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("Usage: patch_engine_sim_core.py PATH_TO_BUILD_ONLY_ENGINE_SIM_SOURCE")
    patch(Path(sys.argv[1]))
    print("Engine Simulator headless cleanup ready")
