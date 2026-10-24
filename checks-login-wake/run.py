#!/usr/bin/env python3
"""macOS-only isolated synthetic integration harness; never targets a shared simulator.

Usage: bash checks-login-wake/run-macos.sh [--output wake-evidence] [--scenarios ...]
Production files are copied verbatim; only the copied PonyApp.swift is replaced.
No real authentication, Keychain, backend or Tesla traffic is used by the fixture.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import time
import uuid

ROOT = Path(__file__).resolve().parent.parent
SCENARIOS = ["success-light", "success-dark", "success-large", "timeout", "unknown",
             "multiple", "cancel", "late", "logout", "restore", "refresh",
             "401-waking", "401-waiting", "401-reading", "401-cancel",
             "no-cache", "unknown404", "429", "network", "decode",
             "deadline-reading", "denied", "confirmation-error"]


def run(args, *, cwd=None, timeout=120, check=True):
    args = [str(a) for a in args]
    print("+", " ".join(args), flush=True)
    result = subprocess.run(args, cwd=cwd, text=True, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, timeout=timeout)
    if check and result.returncode:
        raise RuntimeError(f"Command failed ({result.returncode}): {' '.join(args)}\n{result.stdout}")
    return result


def sim(*args, **kwargs):
    return run(["xcrun", "simctl", *args], **kwargs)


def digest_tree(path):
    return {str(p.relative_to(path)): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in path.rglob("*") if p.is_file() and not any(x in p.parts for x in [".build", "DerivedData", "xcuserdata"])}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", default="wake-evidence")
    parser.add_argument("--scenarios", nargs="+", choices=SCENARIOS, default=SCENARIOS)
    args = parser.parse_args()
    if sys.platform != "darwin":
        parser.error("This harness must be run on the disposable macOS builder")
    output = Path(args.output).resolve()
    output.mkdir(parents=True, exist_ok=True)
    before = digest_tree(ROOT / "ios")
    device = None
    results = []
    metadata = {"synthetic": True, "scenarios": args.scenarios,
                "limits": ["No real-car or server at-most-once evidence", "Browser and storage are synthetic/in-memory",
                           "Phase captures are actual rendered fixture windows, not OCR-verified",
                           "Cancellation suppresses URLProtocol delivery; does not force uncancellable late delivery" ]}
    scratch_root = ROOT / ".airbuild"
    scratch_root.mkdir(exist_ok=True)
    scratch = Path(tempfile.mkdtemp(prefix="login-wake-fixture-", dir=scratch_root))
    try:
        runtimes = json.loads(sim("list", "runtimes", "--json").stdout)["runtimes"]
        types = json.loads(sim("list", "devicetypes", "--json").stdout)["devicetypes"]
        ios = [r for r in runtimes if r.get("isAvailable") and "iOS" in r.get("name", "")]
        if not ios:
            raise RuntimeError("No available iOS simulator runtime")
        runtime = max(ios, key=lambda r: tuple(int(x) for x in r["version"].split(".")))
        major = int(runtime["version"].split(".")[0])
        compatible = [t for t in types if t.get("productFamily") == "iPhone"
                      and int(t.get("minRuntimeVersion", 0)) <= (major << 16)
                      and int(t.get("maxRuntimeVersion", 0xFFFFFFFF)) >= (major << 16)]
        if not compatible:
            raise RuntimeError("No compatible iPhone device type for discovered runtime")
        device_type = compatible[-1]
        metadata.update(runtime=runtime, device_type=device_type)
        device = sim("create", "Pony-SYNTHETIC-login-wake-" + uuid.uuid4().hex[:8],
                     device_type["identifier"], runtime["identifier"]).stdout.strip()
        sim("boot", device)
        sim("bootstatus", device, "-b", timeout=240)
        copied = scratch / "ios"
        shutil.copytree(ROOT / "ios", copied, ignore=shutil.ignore_patterns(".build", "DerivedData", "xcuserdata"))
        copied_entry = copied / "Pony" / "PonyApp.swift"
        original_entry = copied_entry.read_bytes()
        tabs_marker = b"enum PonyTab:"
        tabs_start = original_entry.find(tabs_marker)
        if tabs_start < 0:
            raise RuntimeError("Production PonyApp.swift has no enum PonyTab: suffix to preserve")
        production_tabs = original_entry[tabs_start:]
        fixture_entry = (ROOT / "checks-login-wake" / "Fixture.swift").read_bytes()
        if tabs_marker in fixture_entry:
            raise RuntimeError("Fixture unexpectedly duplicates production tab declarations")
        copied_entry.write_bytes(fixture_entry.rstrip() + b"\n\n" + production_tabs)
        assembled_entry = copied_entry.read_bytes()
        appended_start = assembled_entry.index(tabs_marker)
        tabs_preserved = assembled_entry[appended_start:] == production_tabs
        if not tabs_preserved:
            raise RuntimeError("Copied production PonyTab/PonyTabs suffix differs from original bytes")
        metadata["productionTabsPreserved"] = True
        metadata["productionTabsSHA256"] = hashlib.sha256(production_tabs).hexdigest()
        copied_hashes = digest_tree(copied)
        changed = [p for p in before if before[p] != copied_hashes.get(p)]
        if changed != ["Pony/PonyApp.swift"]:
            raise RuntimeError(f"Disposable copy changed unexpected source paths: {changed}")
        metadata["copied_source_changes"] = changed
        metadata["production_source_sha256"] = before
        # The managed wrapper supports archive/test, not the build action used here.
        # Use Apple's xcodebuild directly for this unsigned disposable simulator build.
        tool = os.environ.get("AIRBUILD_XCODE", "xcodebuild")
        build_args = [tool, "-project", copied / "Pony.xcodeproj", "-scheme", "Pony",
                      "-configuration", "Debug", "-destination", "id=" + device,
                      "-derivedDataPath", scratch / "DerivedData", "CODE_SIGNING_ALLOWED=NO",
                      "PRODUCT_BUNDLE_IDENTIFIER=party.ponypro.LoginWakeSynthetic", "build"]
        built = run(build_args, cwd=copied, timeout=600, check=False)
        (output / "build.log").write_text(built.stdout)
        if built.returncode:
            raise RuntimeError("Fixture build failed; see build.log")
        app = scratch / "DerivedData" / "Build" / "Products" / "Debug-iphonesimulator" / "Pony.app"
        with (app / "Info.plist").open("rb") as f:
            bundle_id = plistlib.load(f)["CFBundleIdentifier"]
        metadata["bundle_id"] = bundle_id
        sim("install", device, app)
        for scenario in args.scenarios:
            scenario_dir = output / scenario
            scenario_dir.mkdir(exist_ok=True)
            sim("terminate", device, bundle_id, check=False)
            container = Path(sim("get_app_container", device, bundle_id, "data").stdout.strip())
            docs = container / "Documents"
            docs.mkdir(exist_ok=True)
            for old in docs.glob("合成验证-*.png"):
                old.unlink()
            (docs / "assertions.json").unlink(missing_ok=True)
            sim("launch", device, bundle_id, "--fixture-scenario", scenario)
            deadline = time.monotonic() + 85
            report_file = docs / "assertions.json"
            while not report_file.exists() and time.monotonic() < deadline:
                time.sleep(0.25)
            if not report_file.exists():
                sim("io", device, "screenshot", scenario_dir / "合成验证-watchdog.png", check=False)
                results.append({"scenario": scenario, "result": "fail", "error": "No assertions.json before watchdog"})
                continue
            report = json.loads(report_file.read_text())
            shutil.copy2(report_file, scenario_dir / "assertions.json")
            for image in docs.glob("合成验证-*.png"):
                shutil.copy2(image, scenario_dir / image.name)
            sim("io", device, "screenshot", scenario_dir / "合成验证-simctl-account.png")
            valid = (report.get("synthetic") is True and report.get("scenario") == scenario
                     and report.get("result") == "pass" and bool(report.get("assertions"))
                     and all(a.get("passed") is True for a in report["assertions"]))
            results.append({"scenario": scenario, "result": "pass" if valid else "fail", "report": report})
            print(f"{scenario}: {'PASS' if valid else 'FAIL'}", flush=True)
    except Exception as error:
        metadata["error"] = str(error)
        print(str(error), file=sys.stderr)
    finally:
        # Never shutdown/delete a pre-existing or shared device; only the newly-created UUID.
        if device:
            try:
                sim("shutdown", device, check=False)
            finally:
                sim("delete", device, check=False)
        metadata["production_sources_unchanged"] = digest_tree(ROOT / "ios") == before
        metadata["results"] = results
        metadata["result"] = "pass" if (len(results) == len(args.scenarios)
            and all(r["result"] == "pass" for r in results)
            and metadata["production_sources_unchanged"] and "error" not in metadata) else "fail"
        (output / "summary.json").write_text(json.dumps(metadata, ensure_ascii=False, indent=2))
        shutil.rmtree(scratch, ignore_errors=True)
    return 0 if metadata["result"] == "pass" else 1


if __name__ == "__main__":
    raise SystemExit(main())
