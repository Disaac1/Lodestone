#!/usr/bin/env python3
"""
Wayfinder 1-Click Install Diagnostics & E2E Test Suite Runner
=============================================================
Runs the headless GDScript E2E install test suite, verifying mock game
scaffolding, ZIP decompression, modloader configurations, host.yaml sync,
and file tree diffing.

Usage:
  python tools/run_install_tests.py
"""

import sys
import os
import subprocess
from pathlib import Path

WORKSPACE_ROOT = Path(__file__).resolve().parent.parent
CLIENT_DIR = WORKSPACE_ROOT / "client"

def find_godot_binary():
    candidates = [
        CLIENT_DIR / "godot_console.exe",
        CLIENT_DIR / "godot.exe",
        Path("godot_console.exe"),
        Path("godot.exe")
    ]
    for c in candidates:
        if c.exists():
            return str(c)
    # Check system PATH
    where = shutil_which("godot_console") or shutil_which("godot")
    if where:
        return where
    return None

def shutil_which(cmd):
    import shutil
    return shutil.which(cmd)

def main():
    print("=" * 66)
    print("  WAYFINDER 1-CLICK INSTALL E2E TEST RUNNER")
    print("=" * 66)

    godot_bin = find_godot_binary()
    if not godot_bin:
        print("[ERROR] Godot executable (godot_console.exe) was not found in client/ or PATH!")
        sys.exit(1)

    print(f"Godot Binary : {godot_bin}")
    print(f"Client Dir   : {CLIENT_DIR}")
    test_script_res = "res://scripts/tests/test_e2e_install_diagnostics.gd"

    cmd = [
        godot_bin,
        "--headless",
        "--path",
        str(CLIENT_DIR),
        "-s",
        test_script_res
    ]

    print("\nExecuting test harness...\n")
    proc = subprocess.run(cmd, text=True)
    if proc.returncode == 0:
        print("\n[SUCCESS] All 1-Click Install Diagnostics & E2E tests succeeded!")
    else:
        print(f"\n[FAILURE] Test suite failed with exit code: {proc.returncode}")
    sys.exit(proc.returncode)

if __name__ == "__main__":
    main()
