#!/usr/bin/env python3
"""Summarize raw local pipeline JSON reports without inferring total system RAM.

Usage: python3 Tools/report_pipeline_benchmark.py /absolute/path/to/reports
"""
import argparse
import json
from pathlib import Path


def summarize(directory):
    reports = []
    for path in sorted(directory.glob("*.json")):
        value = json.loads(path.read_text())
        if "samples" in value:
            samples = value["samples"]
            phases = {}
            for sample in samples:
                phases.setdefault(sample["phase"], []).append(sample)
            fields = ("residentBytes", "physicalFootprintBytes", "mlxActiveBytes", "mlxCacheBytes")

            def peaks(rows):
                return {field: max((row.get(field) or 0 for row in rows), default=0)
                        for field in fields}

            reports.append({"file": path.name, "kind": "sampled_memory",
                            "sample_count": len(samples), "baseline": samples[0] if samples else None,
                            "peak": peaks(samples), "final": samples[-1] if samples else None,
                            "phase_peaks": {name: peaks(rows) for name, rows in phases.items()},
                            "interpretation": value["interpretation"]})
        elif "evaluation" in value:
            reports.append({key: value[key] for key in ("id", "modelID", "elapsedSeconds", "passCount", "cacheCondition", "evaluation")})
        elif "wordErrorRate" in value:
            result = {key: value[key] for key in ("id", "modelID", "audioSeconds", "modelLoadSeconds", "elapsedSeconds", "wordErrorRate", "missingPhrases", "passed")}
            result["real_time_factor"] = value["elapsedSeconds"] / value["audioSeconds"] if value["audioSeconds"] else None
            reports.append(result)
        elif "status" in value or "error" in value:
            reports.append(value)
    for path in sorted(directory.glob("*services*.jsonl")):
        rows = [json.loads(line) for line in path.open() if line.strip()]
        host = [row["host_memory"] for row in rows if row.get("host_memory_refreshed") and row.get("host_memory")]

        def counter_ranges(group):
            names = set().union(*(sample.get(group, {}).keys() for sample in host)) if host else set()
            result = {}
            for name in names:
                values = [sample[group][name] for sample in host if name in sample.get(group, {})]
                result[name] = {"baseline": values[0], "peak": max(values), "minimum": min(values), "final": values[-1]}
            return result

        pressure = [sample["memory_pressure_free_percent"] for sample in host if sample.get("memory_pressure_free_percent") is not None]
        service_samples = {}
        for row in rows:
            for process in row.get("apple_services", []):
                key = str(process["pid"]) + ":" + process["command"]
                service_samples.setdefault(key, []).append(process["rss_bytes"])
        reports.append({"file": path.name, "kind": "host_and_external_service_observations",
                        "host_sample_count": len(host), "host_vm_bytes": counter_ranges("vm_bytes"),
                        "host_swap_bytes": counter_ranges("swap_bytes"),
                        "memory_pressure_free_percent": {"baseline": pressure[0], "minimum": min(pressure), "final": pressure[-1]} if pressure else None,
                        "services_rss_bytes": {key: {"first_observed": values[0], "peak": max(values), "last_observed": values[-1]}
                                               for key, values in service_samples.items()},
                        "attribution": "Host counters include all apps and kernel workloads; changes are observational and cannot be solely attributed to Sekitiri. Service RSS is separate, shared and non-additive."})
    return {"reports": reports,
            "ram_warning": "RSS, physical footprint and MLX allocations are alternative overlapping views, never additive. External service RSS is separate and not solely attributable to this app."}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    args = parser.parse_args()
    print(json.dumps(summarize(args.directory), ensure_ascii=False, indent=2))
