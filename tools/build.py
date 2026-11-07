#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Builds dist/com.astra.whatsastra.apkg: the WhatsApp service (service/, Go, for
the phone: linux/arm64, static) into the app's bin/, then the package with the
astraOS SDK (`astra build`: the design language check, then the package).

  python3 tools/build.py --astra ../astra [--build-number N]

Needs Go (https://go.dev) 1.24 or newer.
"""
import argparse
import json
import os
import shutil
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

ap = argparse.ArgumentParser()
ap.add_argument("--astra", default=os.environ.get("ASTRA_SRC", os.path.join(ROOT, "..", "astra")))
ap.add_argument("--build-number", type=int, default=int(os.environ.get("BUILD_NUMBER", "0")))
ap.add_argument("-o", "--out", default=os.path.join(ROOT, "dist"))
args = ap.parse_args()

app_dir = os.path.join(ROOT, "build", "app")
shutil.rmtree(app_dir, ignore_errors=True)
shutil.copytree(os.path.join(ROOT, "app"), app_dir)
m = json.load(open(os.path.join(app_dir, "app.json"), encoding="utf-8"))
m["versionCode"] = int(m["versionCode"]) + args.build_number
if args.build_number:
    m["version"] = f'{m["version"]}.{args.build_number}'
json.dump(m, open(os.path.join(app_dir, "app.json"), "w", encoding="utf-8", newline="\n"), indent=4, ensure_ascii=False)
# The service: static, no C library needed (pure Go SQLite), for astraOS's phones.
os.makedirs(os.path.join(app_dir, "bin"), exist_ok=True)
env = dict(os.environ, CGO_ENABLED="0", GOOS="linux", GOARCH=os.environ.get("GOARCH", "arm64"))
subprocess.run(["go", "build", "-trimpath", "-ldflags", "-s -w", "-o",
                os.path.join(app_dir, "bin", "whatsastra-service"), "."],
               cwd=os.path.join(ROOT, "service"), env=env, check=True)
os.chmod(os.path.join(app_dir, "bin", "whatsastra-service"), 0o755)
os.makedirs(args.out, exist_ok=True)
out = os.path.join(args.out, m["package"] + ".apkg")
subprocess.run([sys.executable, os.path.join(args.astra, "sdk", "bin", "astra"), "build", app_dir, "-o", out], check=True)
json.dump({"version": m["version"], "versionCode": m["versionCode"]}, open(os.path.join(args.out, "release.json"), "w"), indent=2)
print(out, m["version"], m["versionCode"])
