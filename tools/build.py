#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Builds dist/com.astra.whatsastra.apkg with astraOS's apkgtool.

  python3 tools/build.py --astra ../astra [--build-number N]
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
os.makedirs(args.out, exist_ok=True)
out = os.path.join(args.out, m["package"] + ".apkg")
subprocess.run([sys.executable, os.path.join(args.astra, "tools", "apkgtool", "apkgtool.py"), "pack", app_dir, "-o", out], check=True)
json.dump({"version": m["version"], "versionCode": m["versionCode"]}, open(os.path.join(args.out, "release.json"), "w"), indent=2)
print(out, m["version"], m["versionCode"])
