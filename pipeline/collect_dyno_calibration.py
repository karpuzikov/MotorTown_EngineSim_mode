"""Collect the dyno's best-torque spark advance into the generator's calibration.

    gh run view RUN_ID --log | python3 -I pipeline/collect_dyno_calibration.py

Reads the dyno.json lines a find-mbt run of the "Real-spec engine dyno"
workflow prints, and merges each engine's mbt_spark_advance table into
pipeline/calibration/spark_advance_mbt.json (keyed by engine id).
"""

import json
import re
import sys
from pathlib import Path

CALIBRATION_PATH = Path(__file__).resolve().parent / "calibration" / "spark_advance_mbt.json"
DYNO_JSON_LINE = re.compile(r'(\{"script": "(?P<engine>[^"]+)\.mr".*\})\s*$')


def main():
    calibration = json.loads(CALIBRATION_PATH.read_text()) if CALIBRATION_PATH.exists() else {}
    found = 0
    for line in sys.stdin:
        match = DYNO_JSON_LINE.search(line)
        if not match:
            continue
        table = json.loads(match.group(1)).get("mbt_spark_advance")
        if not table:
            raise SystemExit(f"{match.group('engine')}: run without find-mbt")
        calibration[match.group("engine")] = [[rpm, round(degrees, 2)] for rpm, degrees in table]
        found += 1
    if not found:
        raise SystemExit("no dyno results in the input")
    CALIBRATION_PATH.parent.mkdir(exist_ok=True)
    CALIBRATION_PATH.write_text(json.dumps(dict(sorted(calibration.items())), indent=0) + "\n")
    print(f"{found} engines -> {CALIBRATION_PATH}")


if __name__ == "__main__":
    main()
