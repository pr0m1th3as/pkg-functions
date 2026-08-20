#!/usr/bin/env python3
"""Decide which packages this run has to harvest, and shard them.

Only the newest release of each package is harvested here.  This is the sweep
that keeps up with the present; the past is swept by history.py, which resolves
a whole closure as of the day a release shipped and measures it under the
Octave of that day.  Sending an old release through this planner instead would
build it against today's dependencies, a combination that never existed.
"""

import json
import os
import re
import sys

SHARDS = int(os.environ.get("SHARDS", "8"))
REQUESTED = os.environ.get("REQUESTED", "").split()
FORCE = os.environ.get("FORCE", "").lower() == "true"

DATA = "data"
SAFE_VERSION = re.compile(r"^[A-Za-z0-9._+-]+$")


def newest(entry):
    """The newest release of a package; the index lists it first."""
    versions = entry.get("versions") or []
    return versions[0] if versions else None


def dependency_names(release):
    names = []
    for dep in release.get("depends") or []:
        names.append(dep["name"] if isinstance(dep, dict) else str(dep).split()[0])
    return names


def release_key(sha, version):
    """What identifies a release for caching purposes.

    Sixteen of the index entries carry no sha256 at all, so a bare checksum
    comparison equates all of them to each other and to every absent record.
    Fall back to the version, which is weaker -- a re-cut tarball under an
    unchanged version is invisible to it -- but never silently universal.
    """
    if sha:
        return "sha256:" + sha
    return "version:" + version if version else None


def already_held(name, release):
    """True when this exact release has already been measured successfully."""
    version = release.get("id")
    if not version or not SAFE_VERSION.match(version):
        return False
    path = os.path.join(DATA, name, version + ".json")
    try:
        with open(path) as fid:
            record = json.load(fid)
    except (OSError, ValueError):
        return False
    # A failed harvest is retried on the next run, because the failure may well
    # have been the runner rather than the package.
    if record.get("status") != "ok":
        return False
    # A tarball re-cut under an unchanged version number is a different release
    # wearing the same name, and has to be measured again.
    held = release_key(record.get("sha256"), record.get("version"))
    return held is not None and held == release_key(release.get("sha256"),
                                                    version)


def main():
    with open("packages.json") as fid:
        index = json.load(fid)

    wanted, skipped, uninstallable, unusable = [], [], [], []
    for name in sorted(index):
        if REQUESTED and name not in REQUESTED:
            continue
        release = newest(index[name])
        if release is None:
            continue
        version = release.get("id")
        if not version or not SAFE_VERSION.match(version):
            # The version becomes a path component, so it has to be one.
            unusable.append(name)
            continue
        if "pkg" not in dependency_names(release):
            uninstallable.append(name)
            continue
        if not FORCE and already_held(name, release):
            skipped.append(name)
            continue
        wanted.append(name)

    missing = [p for p in REQUESTED if p not in index]
    if missing:
        print("::error::not in the package index: " + " ".join(missing))
        return 1

    print(f"harvest {len(wanted)}, already held {len(skipped)}, "
          f"not pkg-installable {len(uninstallable)}, "
          f"unusable version {len(unusable)}")
    # Named rather than silently dropped: these packages are absent from the
    # data set by rule, not by accident.
    if uninstallable:
        print("not pkg-installable: " + " ".join(uninstallable))
    if unusable:
        print("::warning::unusable version string: " + " ".join(unusable))

    shards = min(SHARDS, len(wanted)) or 1
    buckets = [wanted[ii::shards] for ii in range(shards)]
    matrix = {"include": [{"shard": ii + 1, "packages": " ".join(bucket)}
                          for ii, bucket in enumerate(buckets) if bucket]}

    with open(os.environ["GITHUB_OUTPUT"], "a") as fid:
        fid.write("matrix=" + json.dumps(matrix) + "\n")
        fid.write(f"count={len(wanted)}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
