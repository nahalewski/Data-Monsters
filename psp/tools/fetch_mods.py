#!/usr/bin/env python3
"""
Fetch community mods for the console builds from the authors' own GitHub
repositories, as listed by the official gen1recomp mod index
(https://github.com/bryanthaboi/gen1recomp-mod-index).  Nothing is taken
from gen1recomp.com: upstream's README says that site is unaffiliated and
untrustworthy.

    fetch_mods.py OUT_DIR [--index DIR] [--max-mb N] [--only id,id,...]

Each mod lands in OUT_DIR/<id>/ (the folder holding its manifest.json).
build.sh packs OUT_DIR=psp/mods_extra into the archive next to upstream's
example mods; the folder is gitignored because the mods carry their own
licences.  Mods that need the network, the desktop launcher's voxel
renderer (GLSL) or more than --max-mb of assets are skipped and listed.
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile

SKIP_PERMISSIONS = {"network"}
SKIP_DEPENDS = {"DRAMATIC_SHAPE", "VOXEL_VR", "DRAMALESS_SHAPE", "potato_voxel"}


def size_of(path):
    total = 0
    for root, _, files in os.walk(path):
        for f in files:
            try:
                total += os.path.getsize(os.path.join(root, f))
            except OSError:
                pass
    return total


def main():
    args = sys.argv[1:]
    if not args:
        print(__doc__)
        sys.exit(1)
    out = args[0]
    index = None
    max_mb = 8
    only = None
    i = 1
    while i < len(args):
        if args[i] == "--index":
            index = args[i + 1]; i += 2
        elif args[i] == "--max-mb":
            max_mb = float(args[i + 1]); i += 2
        elif args[i] == "--only":
            only = set(args[i + 1].split(",")); i += 2
        else:
            i += 1
    tmp = tempfile.mkdtemp(prefix="g1mods-")
    if not index:
        index = os.path.join(tmp, "index")
        subprocess.run(["git", "clone", "-q", "--depth", "1",
                        "https://github.com/bryanthaboi/gen1recomp-mod-index", index], check=True)
    block = json.load(open(os.path.join(index, "blocklist.json")))
    blocked_authors = {a.lower() for a in block.get("authors", {})}
    blocked_repos = {r.lower() for r in block.get("repos", {})}
    os.makedirs(out, exist_ok=True)
    report = []
    entries = sorted(os.listdir(os.path.join(index, "mods")))
    for entry in entries:
        meta_path = os.path.join(index, "mods", entry, "meta.json")
        if not os.path.exists(meta_path):
            continue
        meta = json.load(open(meta_path))
        mid = meta.get("id") or entry.split("@", 1)[-1]
        if only and mid not in only:
            continue
        gh = (meta.get("github") or "").strip("/")
        author = (meta.get("author") or "").lower()
        if not gh or gh.lower() in blocked_repos or author in blocked_authors \
                or gh.split("/")[0].lower() in blocked_authors:
            report.append((mid, "skip", "blocklisted or no repo"))
            continue
        perms = set(meta.get("permissions") or [])
        deps = set(meta.get("dependencies") or [])
        if perms & SKIP_PERMISSIONS:
            report.append((mid, "skip", "needs " + ",".join(sorted(perms & SKIP_PERMISSIONS))))
            continue
        if deps & SKIP_DEPENDS:
            report.append((mid, "skip", "needs " + ",".join(sorted(deps & SKIP_DEPENDS))))
            continue
        dest = os.path.join(out, mid)
        if os.path.exists(os.path.join(dest, "manifest.json")):
            report.append((mid, "ok", "already fetched"))
            continue
        src = os.path.join(tmp, mid)
        r = subprocess.run(["git", "clone", "-q", "--depth", "1", "https://github.com/" + gh, src],
                           capture_output=True, text=True)
        if r.returncode != 0:
            report.append((mid, "fail", "clone: " + r.stderr.strip().splitlines()[-1:][0] if r.stderr.strip() else "clone failed"))
            continue
        # the mod is the folder holding manifest.json whose id matches (or the shallowest one)
        found = None
        for root, dirs, files in os.walk(src):
            dirs[:] = [d for d in dirs if d != ".git"]
            if "manifest.json" in files:
                try:
                    m = json.load(open(os.path.join(root, "manifest.json")))
                except Exception:
                    continue
                if m.get("id") == mid:
                    found = root
                    break
                if found is None:
                    found = root
        if not found:
            report.append((mid, "fail", "no manifest.json in repo"))
            shutil.rmtree(src, ignore_errors=True)
            continue
        shutil.rmtree(os.path.join(found, ".git"), ignore_errors=True)
        mb = size_of(found) / 1e6
        if mb > max_mb:
            report.append((mid, "skip", "%.1f MB > %g MB" % (mb, max_mb)))
            shutil.rmtree(src, ignore_errors=True)
            continue
        shutil.copytree(found, dest)
        shutil.rmtree(src, ignore_errors=True)
        report.append((mid, "ok", "%.1f MB from %s" % (mb, gh)))
        print("fetched", mid, "%.1f MB" % mb, flush=True)
    shutil.rmtree(tmp, ignore_errors=True)
    with open(os.path.join(out, "FETCH-REPORT.txt"), "w") as f:
        for mid, status, why in report:
            f.write("%-32s %-5s %s\n" % (mid, status, why))
    ok = sum(1 for r in report if r[1] == "ok")
    print("%d fetched, %d skipped, %d failed -> %s" % (
        ok, sum(1 for r in report if r[1] == "skip"), sum(1 for r in report if r[1] == "fail"), out))


if __name__ == "__main__":
    main()
