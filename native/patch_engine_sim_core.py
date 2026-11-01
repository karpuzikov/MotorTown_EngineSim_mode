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
    "synthesizer.cpp": "efcf9bb3f7a3d26c646e0238f3ead1b4ec20b4906fea2f8fd09f7a35d8ff081e",
    "piston_engine_simulator.cpp": "1ef3ae113cdf14ddbb33b21cd3948f3bafd6dce25e775812db74044550ba2a0b",
    "compiler.cpp": "d60cc3f5df0762cafec2f439149490d3235b1954ab31783e14ef2e1f4b0106d7",
    "piranha_path.cpp": "906ffcfc170abf8d4ff778dfdbf5185d388e4481243fcacb865b8d97cf7f1c53",
}

# The user's already-configured Windows build contains this exact previous
# synthesizer patch. Upgrade only that audited revision; never overwrite an
# unknown or hand-edited Engine Simulator checkout.
LEGACY_SYNTHESIZER_PATCHED_SHA = "d04cae09d0da700a77561426d53a843fb498d33e735b78f3681cf74ac70d2c45"
PREVIOUS_SYNTHESIZER_PATCHED_SHA = "c7482d8cb0a8f40bff8db53ead2ed3cb0e991f1c16126229c55a90b7a129d41f"
SINGLE_PACKET_SYNTHESIZER_PATCHED_SHA = "a0b6942cc93910e86b6f336fff73a82e546a36a1d8b37550ddf072a59abc1199"
MONOLITHIC_TWO_PACKET_SYNTHESIZER_PATCHED_SHA = "89a99c1c0cce2e038a2708da5831a2e4a629c28bd2efd473a6b8e0bda71b6768"

# Preserve exact known historical bytes for safe upgrades. Computing 16k PCM
# samples before publishing ANY of them can exceed the 30-ms consumer deadline.
# Stream 1024-sample chunks into the output FIFO under short locks instead.
MONOLITHIC_BATCH = (
    "    std::array<int16_t, 16384> rendered;\n"
    "    for (int i = 0; i < n; ++i) {\n"
    "        rendered[i] = renderAudio(i);\n"
    "    }\n"
    "    {\n"
    "        std::lock_guard<std::mutex> lock(m_lock0);\n"
    "        for (int i = 0; i < n; ++i) m_audioBuffer.write(rendered[i]);\n"
    "    }")
STREAMED_BATCH = (
    "    std::array<int16_t, 1024> rendered;\n"
    "    for (int offset = 0; offset < n; offset += 1024) {\n"
    "        const int chunk = std::min(1024, n - offset);\n"
    "        for (int i = 0; i < chunk; ++i) {\n"
    "            rendered[i] = renderAudio(offset + i);\n"
    "        }\n"
    "        {\n"
    "            std::lock_guard<std::mutex> lock(m_lock0);\n"
    "            for (int i = 0; i < chunk; ++i) m_audioBuffer.write(rendered[i]);\n"
    "        }\n"
    "    }")


def upgrade_monolithic_synthesizer(source: str) -> str:
    if source.count(MONOLITHIC_BATCH) != 1:
        raise ValueError("Unsupported Engine Simulator synth output batching")
    return source.replace(MONOLITHIC_BATCH, STREAMED_BATCH, 1)


def upgrade_legacy_synthesizer(source: str, old_capacity: int = 2000) -> str:
    if old_capacity not in (2000, 4096, 8192):
        raise ValueError("Unsupported legacy Engine Simulator render capacity")
    upgrades = (
        (f"m_audioBuffer.size() < {old_capacity};", "m_audioBuffer.size() < 16384;"),
        (f"std::max(0, {old_capacity} - (int)m_audioBuffer.size()),",
         "std::max(0, 16384 - (int)m_audioBuffer.size()),"),
        (f"std::array<int16_t, {old_capacity}> rendered;",
         "std::array<int16_t, 16384> rendered;"),
    )
    for old, new in upgrades:
        if source.count(old) != 1:
            raise ValueError("Unsupported legacy Engine Simulator render capacity")
        source = source.replace(old, new, 1)
    return source


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
            # The renderer produces at most ONE batch per simulation frame
            # (m_processed waits for endInputBlock). A 150-ms game frame
            # needs 6615 samples; reserve two entire game-frame packets so
            # a late render batch need not immediately starve the consumer.
            # Keep wake and render quota in agreement; publish small chunks.
            ("m_audioBuffer.size() < 2000;",
             "m_audioBuffer.size() < 16384;"),
            ("std::max(0, 2000 - (int)m_audioBuffer.size()),",
             "std::max(0, 16384 - (int)m_audioBuffer.size()),"),
            ("    for (int i = 0; i < n; ++i) {\n"
             "        m_audioBuffer.write(renderAudio(i));\n"
             "    }",
             MONOLITHIC_BATCH + "\n"
             "    " + MARK),
        )
        for before, after in replacements:
            if source.count(before) != 1:
                raise ValueError("Unsupported synthesizer layout: " + before.strip())
            source = source.replace(before, after, 1)
        return upgrade_monolithic_synthesizer(source)

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
    unpatched = 0
    for name, expected_hash in FILES.items():
        if name == "piranha_path.cpp":
            path = root / "dependencies/submodules/piranha/src/path.cpp"
        else:
            path = root / ("scripting/src" if name == "compiler.cpp" else "src") / name
        raw = path.read_bytes()
        source = raw.decode("utf-8").replace("\r\n", "\n")
        if MARK in source:
            digest = hashlib.sha256(source.encode("utf-8")).hexdigest()
            if digest == PATCHED_HASHES[name]:
                existing += 1
                continue
            if name == "synthesizer.cpp" and digest in (
                LEGACY_SYNTHESIZER_PATCHED_SHA,
                PREVIOUS_SYNTHESIZER_PATCHED_SHA,
                SINGLE_PACKET_SYNTHESIZER_PATCHED_SHA,
                MONOLITHIC_TWO_PACKET_SYNTHESIZER_PATCHED_SHA,
            ):
                old_capacity = {
                    LEGACY_SYNTHESIZER_PATCHED_SHA: 2000,
                    PREVIOUS_SYNTHESIZER_PATCHED_SHA: 4096,
                    SINGLE_PACKET_SYNTHESIZER_PATCHED_SHA: 8192,
                    MONOLITHIC_TWO_PACKET_SYNTHESIZER_PATCHED_SHA: 16384,
                }[digest]
                upgraded = upgrade_legacy_synthesizer(source, old_capacity) \
                    if old_capacity != 16384 else source
                upgraded = upgrade_monolithic_synthesizer(upgraded)
                if hashlib.sha256(upgraded.encode("utf-8")).hexdigest() != PATCHED_HASHES[name]:
                    raise ValueError("Legacy Engine Simulator upgrade produced unexpected bytes")
                newline = "\r\n" if b"\r\n" in raw else "\n"
                updates[path] = upgraded.replace("\n", newline).encode("utf-8")
                existing += 1
                continue
            else:
                raise ValueError("Modified Engine Simulator patch: " + name)
        if hashlib.sha256(source.encode("utf-8")).hexdigest() != expected_hash:
            raise ValueError("Unknown Engine Simulator revision: " + name)
        replacement = transformed(name, source)
        newline = "\r\n" if b"\r\n" in raw else "\n"
        updates[path] = replacement.replace("\n", newline).encode("utf-8")
        unpatched += 1
    if existing and unpatched:
        raise ValueError("Partially patched Engine Simulator checkout; source untouched")
    for path, data in updates.items():
        path.write_bytes(data)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("Usage: patch_engine_sim_core.py PATH_TO_BUILD_ONLY_ENGINE_SIM_SOURCE")
    patch(Path(sys.argv[1]))
    print("Engine Simulator headless cleanup ready")
