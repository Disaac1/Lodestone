#!/usr/bin/env python3
"""
Wayfinder / Lodestone Backend Regression Test Runner Harness
============================================================
Discovers and executes backend regression tests sequentially against a
running Wayfinder Node.js service, collects results, and outputs a formatted
console summary and GitHub Actions Markdown job summary.

Supported command line arguments:
  --server-url=<url>       Base HTTP URL of backend (default: http://localhost:8080)
  --summary-file=<path>    Write GitHub Actions Markdown test summary to this file
  --filter=<substring>     Filter tests by substring
  --wait-for-server=<sec>  Maximum seconds to wait for backend to be ready (default: 30)
"""

import sys
import os
import time
import subprocess
import urllib.request
import urllib.error
import argparse

DEFAULT_TEST_FILES = [
    "server_lobbies_test.py",
    "test_host_controls_and_recovery.py",
    "test_multiplayer_session_resilience.py",
    "test_inactivity_auto_delete.py",
    "backend_lockdown_test.py",
    "test_release_sync_and_downloads.py",
    "test_multiplayer_generation_and_sync.py",
    "test_yaml_templates_download.py",
]

def parse_args():
    parser = argparse.ArgumentParser(description="Wayfinder Backend Regression Test Runner")
    parser.add_argument("--server-url", default="http://localhost:8080", help="Backend HTTP URL")
    parser.add_argument("--summary-file", default="", help="Path to write GitHub Actions markdown summary")
    parser.add_argument("--filter", default="", help="Filter tests by name")
    parser.add_argument("--wait-for-server", type=int, default=30, help="Seconds to wait for server health")
    parser.add_argument("--skip-server-check", action="store_true", help="Skip waiting for server health check")
    return parser.parse_args()

def wait_for_server(url, max_seconds=30):
    print(f"Waiting for backend at {url} to become ready (max {max_seconds}s)...")
    start = time.time()
    health_endpoint = f"{url.rstrip('/')}/api/games"
    while time.time() - start < max_seconds:
        try:
            req = urllib.request.Request(health_endpoint, headers={"User-Agent": "CI-Test-Runner"})
            with urllib.request.urlopen(req, timeout=2) as resp:
                if resp.status == 200:
                    print(f"✅ Backend is online and responsive ({time.time() - start:.2f}s).")
                    return True
        except Exception:
            time.sleep(1)
    print(f"❌ Backend did not respond at {health_endpoint} within {max_seconds}s.")
    return False

def locate_test_file(filename):
    # Check backend/tests/, root ., and relative paths
    search_dirs = [
        os.path.join(os.path.dirname(__file__), "..", "backend", "tests"),
        os.path.join(os.path.dirname(__file__), ".."),
        os.path.join(os.getcwd(), "backend", "tests"),
        os.getcwd(),
    ]
    for d in search_dirs:
        candidate = os.path.abspath(os.path.join(d, filename))
        if os.path.isfile(candidate):
            return candidate
    return None

def write_markdown_summary(summary_path, results, total_passed, total_failed, duration):
    md = []
    md.append("## 🚀 Backend Node.js / Python Regression Test Results\n")
    
    if total_failed == 0:
        md.append("✅ **All Backend Regression Tests Passed**\n")
    else:
        md.append(f"❌ **{total_failed} Backend Test(s) Failed**\n")
        
    md.append("| Metric | Value |")
    md.append("| :--- | :--- |")
    md.append(f"| **Total Tests** | {len(results)} |")
    md.append(f"| **Passed** | {total_passed} |")
    md.append(f"| **Failed** | {total_failed} |")
    md.append(f"| **Total Duration** | {duration:.2f}s |\n")
    
    md.append("### Test Breakdown\n")
    md.append("| Status | Test Name | Duration | Exit Code |")
    md.append("| :---: | :--- | :---: | :---: |")
    for r in results:
        badge = "✅ Pass" if r["status"] == "PASSED" else "❌ Fail"
        md.append(f"| {badge} | `{r['name']}` | {r['duration']:.2f}s | `{r['exit_code']}` |")
    md.append("")
    
    if total_failed > 0:
        md.append("### 🔍 Failure Details\n")
        for r in results:
            if r["status"] == "FAILED":
                md.append(f"<details><summary><b>{r['name']}</b> (Exit code {r['exit_code']})</summary>\n")
                md.append("```text")
                md.append(r["log"].strip())
                md.append("```\n</details>\n")
                
    with open(summary_path, "w", encoding="utf-8") as f:
        f.write("\n".join(md))
    print(f"Wrote Markdown summary to {summary_path}")

def main():
    if hasattr(sys.stdout, 'reconfigure'):
        sys.stdout.reconfigure(encoding='utf-8', errors='replace')
    if hasattr(sys.stderr, 'reconfigure'):
        sys.stderr.reconfigure(encoding='utf-8', errors='replace')
    args = parse_args()
    
    print("=" * 66)
    print("      WAYFINDER / LODESTONE BACKEND REGRESSION TEST HARNESS       ")
    print("=" * 66)
    print(f"Python Binary : {sys.executable}")
    print(f"Server Target : {args.server_url}")
    
    # 1. Server Health Check
    if not args.skip_server_check:
        is_ready = wait_for_server(args.server_url, args.wait_for_server)
        if not is_ready:
            print("\n❌ Aborting test suite: Backend service is not reachable.")
            sys.exit(1)
            
    # 2. Discover test scripts
    tests_to_run = []
    for test_name in DEFAULT_TEST_FILES:
        if args.filter and args.filter.lower() not in test_name.lower():
            continue
        path = locate_test_file(test_name)
        if path:
            tests_to_run.append((test_name, path))
        else:
            print(f"⚠️  Warning: Test file '{test_name}' could not be located on disk.")
            
    if not tests_to_run:
        print("❌ No test scripts matched the criteria.")
        sys.exit(1)
        
    print(f"Discovered    : {len(tests_to_run)} backend regression test(s)\n")
    
    results = []
    total_passed = 0
    total_failed = 0
    suite_start = time.time()
    
    # 3. Execute tests sequentially
    for idx, (name, path) in enumerate(tests_to_run, 1):
        print(f"[{idx}/{len(tests_to_run)}] RUNNING: {name}...")
        test_start = time.time()
        
        try:
            proc = subprocess.run(
                [sys.executable, path],
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                cwd=os.path.dirname(path),
                timeout=120
            )
            duration = time.time() - test_start
            log_output = proc.stdout or ""
            returncode = proc.returncode
        except subprocess.TimeoutExpired as te:
            duration = time.time() - test_start
            returncode = -1
            log_output = (te.stdout or "") + f"\n\n[TIMEOUT ERROR] Test exceeded maximum timeout of 120 seconds."
        
        if returncode == 0:
            print(f"       ✅ PASS: {name} ({duration:.2f}s)")
            results.append({
                "name": name,
                "status": "PASSED",
                "exit_code": 0,
                "duration": duration,
                "log": log_output
            })
            total_passed += 1
        else:
            print(f"       ❌ FAIL: {name} (Exit code: {returncode}, {duration:.2f}s)")
            tail_lines = log_output.strip().splitlines()[-15:]
            print("       --- Log Snippet (Last 15 lines) ---")
            for line in tail_lines:
                print(f"       | {line}")
            print("       ------------------------------------")
            results.append({
                "name": name,
                "status": "FAILED",
                "exit_code": returncode,
                "duration": duration,
                "log": log_output
            })
            total_failed += 1
            
    total_duration = time.time() - suite_start
    
    # 4. Print Summary
    print("\n" + "=" * 66)
    print("                     BACKEND TEST RUN SUMMARY                     ")
    print("=" * 66)
    print(f" Total Tests : {len(tests_to_run)}")
    print(f" Passed      : {total_passed}")
    print(f" Failed      : {total_failed}")
    print(f" Total Time  : {total_duration:.2f} seconds")
    print("=" * 66)
    
    if total_failed > 0:
        print("\nFailed Tests:")
        for r in results:
            if r["status"] == "FAILED":
                print(f" - {r['name']} (Exit code: {r['exit_code']})")
        print("")
        
    if args.summary_file:
        write_markdown_summary(args.summary_file, results, total_passed, total_failed, total_duration)
        
    sys.exit(1 if total_failed > 0 else 0)

if __name__ == "__main__":
    main()
