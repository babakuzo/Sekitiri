#!/usr/bin/env python3
"""Sample process RSS and Apple model services while an explicit benchmark runs.

Run: python3 Tools/sample_pipeline_memory.py --output /tmp/memory.jsonl -- command args
or:  python3 Tools/sample_pipeline_memory.py --pid PID --output /tmp/memory.jsonl

No network access or model loading. Service RSS is separate, may include shared
pages and unrelated workloads, and must never be added to app RSS as total RAM.
The Swift benchmark reports task physical footprint and MLX allocation samples.
"""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import time


def processes():
    result = subprocess.run(["/bin/ps", "-axo", "pid=,ppid=,rss=,comm="],
                            capture_output=True, text=True, check=True)
    rows = []
    for line in result.stdout.splitlines():
        pieces = line.strip().split(None, 3)
        if len(pieces) == 4:
            rows.append({"pid": int(pieces[0]), "ppid": int(pieces[1]),
                         "rss_bytes": int(pieces[2]) * 1024, "command": pieces[3]})
    return rows


def descendants(rows, parent):
    selected = {parent}
    while True:
        expanded = selected | {row["pid"] for row in rows if row["ppid"] in selected}
        if expanded == selected:
            return selected
        selected = expanded


def counter_output(command):
    try:
        result = subprocess.run(command, capture_output=True, text=True, timeout=2, check=True)
        return result.stdout, None
    except (OSError, subprocess.SubprocessError) as error:
        return "", str(error)


def host_memory():
    """Whole-host counters: observational only, never attributed to Sekitiri."""
    output, error = counter_output(["/usr/bin/vm_stat"])
    size = re.search(r"page size of (\d+) bytes", output)
    page_size = int(size.group(1)) if size else None
    counters = {name.strip().strip('"'): int(number)
                for name, number in re.findall(r"^([^:\n]+):\s+(\d+)\.", output, re.M)}
    byte_counters = {name: counters[name] * page_size
                     for name in ("Pages free", "Pages active", "Pages inactive", "Pages speculative",
                                  "Pages wired down", "Pages occupied by compressor")
                     if page_size and name in counters}
    swap_text, swap_error = counter_output(["/usr/sbin/sysctl", "-n", "vm.swapusage"])
    units = {"K": 1024, "M": 1024 ** 2, "G": 1024 ** 3, "T": 1024 ** 4}
    swap = {name: int(float(number) * units[unit])
            for name, number, unit in re.findall(r"(total|used|free)\s*=\s*([\d.]+)([KMGT])", swap_text)}
    pressure_text, pressure_error = counter_output(["/usr/bin/memory_pressure", "-Q"])
    free = re.search(r"System-wide memory free percentage:\s*(\d+)%", pressure_text)
    return {"page_size_bytes": page_size, "vm_page_counters": counters,
            "vm_bytes": byte_counters, "swap_bytes": swap,
            "memory_pressure_free_percent": int(free.group(1)) if free else None,
            "access_errors": {key: value for key, value in
                              (("vm_stat", error), ("swapusage", swap_error), ("memory_pressure", pressure_error)) if value},
            "not_attributable_to_benchmark": True}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--pid", type=int)
    parser.add_argument("--interval", type=float, default=0.2)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if bool(args.pid) == bool(command):
        parser.error("supply exactly one of --pid or a command after --")
    child = subprocess.Popen(command) if command else None
    pid = child.pid if child else args.pid
    args.output.parent.mkdir(parents=True, exist_ok=True)
    started = time.monotonic()
    host_last_sampled = float("-inf")
    host_sample = None
    with args.output.open("w") as stream:
        while True:
            access_error = None
            try:
                rows = processes()
            except (OSError, subprocess.CalledProcessError) as error:
                rows = []
                access_error = str(error)
            selected = descendants(rows, pid)
            # Do not inspect arguments: they can contain user text or credentials.
            services = [row for row in rows if any(fragment in row["command"].lower()
                        for fragment in ("modelservice", "modelmanager", "modelcatalog",
                                         "intelligenceplatform", "coreml", "aneuser",
                                         "anecompiler", "appleintelligence", "inferenceprovider",
                                         "generativeexperiences", "mtlcompilerservice", "/aned"))]
            now = time.monotonic()
            host_refreshed = now - host_last_sampled >= 1
            if host_refreshed:
                host_sample = host_memory()
                host_last_sampled = now
            sample = {"elapsed_seconds": time.monotonic() - started,
                      "processes": [row for row in rows if row["pid"] in selected],
                      "apple_services": services,
                      "service_process_access_error": access_error,
                      "host_memory": host_sample, "host_memory_refreshed": host_refreshed,
                      "rss_is_not_total_physical_ram": True}
            stream.write(json.dumps(sample) + "\n")
            stream.flush()
            if child is not None:
                if child.poll() is not None:
                    return child.returncode
            elif access_error is None:
                if not any(row["pid"] == pid for row in rows):
                    return 0
            else:
                try:
                    os.kill(pid, 0)
                except ProcessLookupError:
                    return 0
            time.sleep(max(0.1, args.interval))


if __name__ == "__main__":
    raise SystemExit(main())
