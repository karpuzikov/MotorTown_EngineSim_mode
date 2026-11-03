"""Compare dynamometer results with each engine's rated figures.

    python3 -I pipeline/compare_dyno_to_rated.py RESULTS_DIR

RESULTS_DIR holds manifest.json (from generate_engine_scripts.py) and one
<engine_id>/dyno.json per engine. Prints one line per engine and writes
RESULTS_DIR/summary.json. Measures only; nothing is tuned from here.
"""

import json
import sys
from pathlib import Path


def percent_error(measured, rated):
    return None if not rated else round(100.0 * (measured - rated) / rated, 1)


def summarize(results_dir):
    manifest = json.loads((results_dir / "manifest.json").read_text())
    rows = []
    for entry in manifest:
        row = {"engine": entry["engine"], "not_modelled": entry["not_modelled"]}
        dyno_file = results_dir / entry["engine"] / "dyno.json"
        if "skipped" in entry:
            row["status"] = "skipped: " + entry["skipped"]
        elif not (results_dir / f"{entry['engine']}.log").exists():
            continue  # run by another shard
        elif not dyno_file.exists():
            row["status"] = "failed"
        else:
            points = json.loads(dyno_file.read_text())["points"]
            peak_torque = max(points, key=lambda p: p["torque_nm"])
            peak_power = max(points, key=lambda p: p["power_hp"])
            rated = entry["rated"]
            row.update({
                "status": "measured",
                "torque_nm": round(peak_torque["torque_nm"]), "torque_rpm": peak_torque["rpm"],
                "power_hp": round(peak_power["power_hp"]), "power_rpm": peak_power["rpm"],
                "torque_error_pct": percent_error(peak_torque["torque_nm"], rated["torque_nm"]),
                "power_error_pct": percent_error(peak_power["power_hp"], rated["power_hp"]),
                "rated": rated,
                "max_rms_dbfs": round(max(p["rms_dbfs"] for p in points), 1),
                "max_clipped_fraction": max(p["clipped_fraction"] for p in points),
            })
        rows.append(row)
    return rows


def signed(percent):
    return "unrated" if percent is None else f"{percent:+}%"


def main(arguments):
    results_dir = Path(arguments[0])
    rows = summarize(results_dir)
    (results_dir / "summary.json").write_text(json.dumps(rows, indent=1))
    for row in rows:
        if row["status"] != "measured":
            print(f"{row['engine']:28} {row['status']}")
            continue
        rated = row["rated"]
        print(f"{row['engine']:28} power {row['power_hp']:5} hp @{row['power_rpm']:5.0f} "
              f"(rated {rated['power_hp']} @{rated['power_rpm']}, {signed(row['power_error_pct'])})  "
              f"torque {row['torque_nm']:5} N*m @{row['torque_rpm']:5.0f} "
              f"(rated {rated['torque_nm']} @{rated['torque_rpm']}, {signed(row['torque_error_pct'])})  "
              f"level {row['max_rms_dbfs']} dBFS  "
              f"{'not modelled: ' + ', '.join(row['not_modelled']) if row['not_modelled'] else ''}")
    measured = [row for row in rows if row["status"] == "measured" and row["power_error_pct"] is not None]
    if measured:
        mean_abs = sum(abs(row["power_error_pct"]) for row in measured) / len(measured)
        print(f"\n{len(measured)} measured, mean |power error| {mean_abs:.1f}%")


if __name__ == "__main__":
    main(sys.argv[1:])
