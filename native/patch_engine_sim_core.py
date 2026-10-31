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
    "engine.cpp": "b8a5d4c21bccd65ae684654ec280a45de93cef8d8f16b47b2ded6a2d7761bfbe",
    "jitter_filter.cpp": "b09a6b6e2406bc78161aba276ad551c3c2e4c8d1a3b5e8fc7d3cfa16aff1c439",
    "simulator.cpp": "3a014d5dd7e2584250db33605fc51d07d1f7779b811f92c8599d19a654831eb4",
    "synthesizer.cpp": "8ec3421e98b32f811cb3fcc8453ed30de77fef1fe4fc6a2fcb69421175ae34e8",
    "piston_engine_simulator.cpp": "0da7b8fd41e2da0074e19f1ed056e56f24c512c67ac828460355c8549eec38ad",
    "compiler.cpp": "71314012594c46ee8b6151abdf8170cec88ed1cb1d5a2dcbc7bf95a17bbeed3e",
    "piranha_path.cpp": "c1f572d036768b1c049679fb8952c31d7ffb118d76318fce7250ac68ddb14fad",
}
PATCHED_HASHES = {
    "engine.cpp": "939ee10e9d80ea2c075a91ee49be110889d9be25d71513c5d7ab0f4c27567932",
    "jitter_filter.cpp": "fca57c9efa6745a007eaf8582cb6923aac49de0c589cfa77a30128c3175781a5",
    "simulator.cpp": "73c2d9b2e2f29ff00a83c43e19a0d81ccd2ca6cfc6cecf20eb3997318e611d24",
    "synthesizer.cpp": "d04cae09d0da700a77561426d53a843fb498d33e735b78f3681cf74ac70d2c45",
    "piston_engine_simulator.cpp": "1ef3ae113cdf14ddbb33b21cd3948f3bafd6dce25e775812db74044550ba2a0b",
    "compiler.cpp": "d60cc3f5df0762cafec2f439149490d3235b1954ab31783e14ef2e1f4b0106d7",
    "piranha_path.cpp": "906ffcfc170abf8d4ff778dfdbf5185d388e4481243fcacb865b8d97cf7f1c53",
}


def transformed(name: str, source: str) -> str:
    if name == "engine.cpp":
        old = "    m_displacement = displacement;\n}"
        new = ("    delete[] min_s;\n"
               "    delete[] max_s;\n"
               "    m_displacement = displacement;\n"
               "    " + MARK + "\n}")
        if source.count(old) != 1:
            raise ValueError("Unsupported engine displacement cleanup")
        return source.replace(old, new, 1)

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

    if name == "jitter_filter.cpp":
        before = "JitterFilter::~JitterFilter() {\n    /* void */\n}"
        after = ("JitterFilter::~JitterFilter() {\n"
                 "    delete[] m_history;\n"
                 "    m_history = nullptr;\n"
                 "    " + MARK + "\n}")
        if source.count(before) != 1:
            raise ValueError("Unsupported JitterFilter destructor")
        return source.replace(before, after, 1)

    if name == "synthesizer.cpp":
        replacements = (
            ("#include <cassert>\n", "#include <cassert>\n#include <array>\n"),
            ("    m_inputSamplesRead = 0;\n\n    m_audioBufferSize = 0;",
             "    m_inputSamplesRead = 0;\n    m_latency = 0;\n\n    m_audioBufferSize = 0;"),
            ("        m_inputChannels[i].data.destroy();\n",
             "        delete[] m_inputChannels[i].transferBuffer;\n"
             "        m_inputChannels[i].transferBuffer = nullptr;\n"
             "        m_inputChannels[i].data.destroy();\n"),
            ("void Synthesizer::writeInput(const double *data) {\n",
             "void Synthesizer::writeInput(const double *data) {\n"
             "    std::lock_guard<std::mutex> lock(m_lock0);\n"),
            ("    std::unique_lock<std::mutex> lk(m_inputLock);",
             "    std::unique_lock<std::mutex> lk(m_lock0);"),
            ("    for (int i = 0; i < n; ++i) {\n"
             "        m_audioBuffer.write(renderAudio(i));\n"
             "    }",
             "    std::array<int16_t, 2000> rendered;\n"
             "    for (int i = 0; i < n; ++i) {\n"
             "        rendered[i] = renderAudio(i);\n"
             "    }\n"
             "    {\n"
             "        std::lock_guard<std::mutex> lock(m_lock0);\n"
             "        for (int i = 0; i < n; ++i) m_audioBuffer.write(rendered[i]);\n"
             "    }\n"
             "    " + MARK),
        )
        for before, after in replacements:
            if source.count(before) != 1:
                raise ValueError("Unsupported synthesizer layout: " + before.strip())
            source = source.replace(before, after, 1)
        return source

    if name == "piston_engine_simulator.cpp":
        replacements = (
            ("    assert(m_antialiasingFilters == nullptr);\n", ""),
            ("    static double lastValveLift[8] = { 0, 0, 0, 0, 0, 0, 0, 0 };\n", ""),
            ("        lastValveLift[i] = head->exhaustValveLift(piston->getCylinderIndex());\n", ""),
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

    if name == "piranha_path.cpp":
        # Boost 1.80+ removed the old synonym `path::is_complete()`.
        before = "    return m_path->is_complete();"
        after = "    return m_path->is_absolute(); // " + MARK
        if source.count(before) != 1:
            raise ValueError("Unsupported Piranha absolute-path check")
        return source.replace(before, after, 1)

    raise ValueError("Unsupported source file " + name)


def patch(root: Path) -> None:
    root = Path(root).resolve()
    updates = {}
    existing = 0
    for name, expected_hash in FILES.items():
        if name == "piranha_path.cpp":
            path = root / "dependencies/submodules/piranha/src/path.cpp"
        else:
            path = root / ("scripting/src" if name == "compiler.cpp" else "src") / name
        raw = path.read_bytes()
        source = raw.decode("utf-8").replace("\r\n", "\n")
        if MARK in source:
            if hashlib.sha256(source.encode("utf-8")).hexdigest() != PATCHED_HASHES[name]:
                raise ValueError("Modified Engine Simulator patch: " + name)
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
