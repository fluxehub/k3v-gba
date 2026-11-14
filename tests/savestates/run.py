#!/usr/bin/env python3
"""Run the self-checking Direct Boot scenarios for gba_savestates in GHDL."""

from __future__ import annotations

import argparse
import shutil
import subprocess
import tempfile
from pathlib import Path


SCENARIOS = {
    0: "direct boot off leaves the BIOS boot untouched",
    1: "cold direct boot, then Reset Core",
    2: "setting is only acted on while the core is off",
    3: "savestate load requested during a direct boot",
    4: "savestate loaded while the core is off",
    5: "core switched off during a direct boot",
    6: "ordinary savestate loads with direct boot enabled",
}

BENCH = "tb_gba_savestates_directboot"


def run_ghdl(project_root: Path, ghdl: str, rtl: Path, scenarios: list[int]) -> None:
    memory_library = (project_root / "src/fpga/gba/SyncRamDual.vhd",)
    sources = (
        project_root / "src/fpga/gba/proc_bus_gba.vhd",
        project_root / "src/fpga/gba/reg_savestates.vhd",
        rtl,
        project_root / f"tests/savestates/{BENCH}.vhd",
    )

    with tempfile.TemporaryDirectory(prefix="k3v-savestates-ghdl-") as work_dir:
        options = ["--std=08", f"--workdir={work_dir}", f"-P{work_dir}"]
        subprocess.run(
            [ghdl, "-a", *options, "--work=MEM", *(str(source) for source in memory_library)],
            check=True,
            cwd=project_root,
        )
        subprocess.run(
            [ghdl, "-a", *options, *(str(source) for source in sources)],
            check=True,
            cwd=project_root,
        )
        subprocess.run([ghdl, "-e", *options, BENCH], check=True, cwd=project_root)

        for scenario in scenarios:
            print(f"GHDL scenario {scenario}: {SCENARIOS[scenario]}", flush=True)
            subprocess.run(
                [ghdl, "-r", *options, BENCH, f"-gSCENARIO={scenario}",
                 "--assert-level=error", "--ieee-asserts=disable-at-0"],
                check=True,
                cwd=project_root,
            )

    print(f"GHDL Direct Boot checks passed ({len(scenarios)} scenarios)")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--require-ghdl",
        action="store_true",
        help="fail instead of skipping RTL simulation when GHDL is unavailable",
    )
    parser.add_argument(
        "--ghdl",
        type=Path,
        help="explicit GHDL executable (useful for a portable toolchain)",
    )
    parser.add_argument(
        "--rtl",
        type=Path,
        help="alternative gba_savestates.vhd to put under test",
    )
    parser.add_argument(
        "--scenario",
        type=int,
        action="append",
        choices=sorted(SCENARIOS),
        help="run only this scenario (may be repeated)",
    )
    args = parser.parse_args()

    project_root = Path(__file__).resolve().parents[2]
    rtl = args.rtl.resolve() if args.rtl else project_root / "src/fpga/gba/gba_savestates.vhd"

    ghdl = str(args.ghdl.resolve()) if args.ghdl else shutil.which("ghdl")
    if ghdl is not None and not Path(ghdl).is_file():
        raise SystemExit(f"GHDL executable does not exist: {ghdl}")
    if ghdl is None:
        message = "GHDL not found; Direct Boot RTL scenarios were not run"
        if args.require_ghdl:
            raise SystemExit(message)
        print(f"WARNING: {message}")
        return 0

    run_ghdl(project_root, ghdl, rtl, args.scenario or sorted(SCENARIOS))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
