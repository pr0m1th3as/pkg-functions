#!/usr/bin/env python3
"""Plan the one-off sweep that rebuilds the ecosystem's past.

The scheduled sweep measures only what is current.  This plans the other thing:
every release the index still lists, each measured under the Octave that was
current on the day it was published, which is the only interpreter its
dependency closure was ever expected to work with.

Which Octave that is comes from .github/octave-images.json, a table of every
release the container registry offers, its date taken from core's own tag and
its image pinned by digest.  A pin matters more here than anywhere else: the
images are rebuilt from time to time, and a rebuild would otherwise change what
"the Octave of 2022" means after the fact.

The era Octave is a floor as well as a choice.  Releases published before the
oldest image are unreachable, and so are the ones whose era Octave is older
than MIN_OCTAVE -- which is how the sweep is taken in stages, since the
harvester needs jsonencode and so cannot run below Octave 7.1.

Work is sharded by image rather than evenly, so that each job pulls one image
and measures everything belonging to it.
"""

import json
import os
import re
import sys

import plan

SHARDS = int(os.environ.get("SHARDS", "8"))
PER_SHARD = int(os.environ.get("PER_SHARD", "6"))
REQUESTED = os.environ.get("REQUESTED", "").split()
MIN_OCTAVE = os.environ.get("MIN_OCTAVE", "7.1.0")
LIMIT = int(os.environ.get("LIMIT", "0"))
IMAGES = os.path.join(".github", "octave-images.json")
REPOSITORY = "ghcr.io/gnu-octave/octave"


def version_key(version):
    """Order versions numerically, so 9.4.0 comes before 11.3.0."""
    parts = []
    for part in version.split("."):
        parts.append((0, int(part), "") if part.isdigit() else (1, 0, part))
    return tuple(parts)


OCTAVE_CONSTRAINT = re.compile(
    r"^\s*octave\s*\(\s*(<=|>=|==|<|>)\s*([^)]+?)\s*\)\s*$")


def octave_constraints(release):
    """The bounds a release puts on the interpreter, as (operator, version)."""
    bounds = []
    for dep in release.get("depends") or []:
        if isinstance(dep, dict):
            if dep.get("name") == "octave" and dep.get("operator"):
                bounds.append((dep["operator"], dep.get("version")))
            continue
        found = OCTAVE_CONSTRAINT.match(str(dep))
        if found:
            bounds.append((found.group(1), found.group(2)))
    return [(op, ver) for op, ver in bounds if ver]


def satisfies(version, bounds):
    """Whether an Octave release meets every bound a package declares.

    A package that declares an upper bound means it, and handing it the
    interpreter of its day regardless guarantees a failure that says nothing
    about the package: "json" forbids Octave 7.1.0 and up, and its era would
    otherwise be exactly that.
    """
    key = version_key(version)
    for op, want in bounds:
        other = version_key(want)
        if op == ">=" and not key >= other:
            return False
        if op == ">" and not key > other:
            return False
        if op == "<=" and not key <= other:
            return False
        if op == "<" and not key < other:
            return False
        if op == "==" and key != other:
            return False
    return True


def era_of(releases, when, bounds=()):
    """The newest Octave released on or before a day, or None before them all.

    A package published the same day as an Octave release is taken to belong to
    that release.  The alternative is to place it with the previous one, which
    for a package cut *because* of a new Octave would be exactly backwards.
    """
    chosen = None
    for release in releases:
        if release["date"] > when:
            break
        if satisfies(release["version"], bounds):
            chosen = release
    return chosen


def main():
    with open("packages.json") as fid:
        index = json.load(fid)
    with open(IMAGES) as fid:
        releases = sorted(json.load(fid)["releases"],
                          key=lambda r: (r["date"], version_key(r["version"])))

    floor = version_key(MIN_OCTAVE)
    items = []
    held = predating = below = uninstallable = undated = 0
    incompatible = 0

    for name in sorted(index):
        if REQUESTED and name not in REQUESTED:
            continue
        for release in index[name].get("versions") or []:
            version = release.get("id")
            when = release.get("date")
            if not version or not plan.SAFE_VERSION.match(version):
                continue
            # A development snapshot carries no date and so belongs to no era.
            if not when:
                undated += 1
                continue
            if "pkg" not in plan.dependency_names(release):
                uninstallable += 1
                continue
            if plan.already_held(name, release):
                held += 1
                continue
            bounds = octave_constraints(release)
            era = era_of(releases, when, bounds)
            if era is None:
                # Two different absences: nothing had been released yet, or
                # nothing that had been met the bounds the package declares.
                if era_of(releases, when) is None:
                    predating += 1
                else:
                    incompatible += 1
                continue
            if version_key(era["version"]) < floor:
                below += 1
                continue
            items.append({"package": name, "version": version,
                          "octave": era["version"], "digest": era["digest"]})

    missing = [p for p in REQUESTED if p not in index]
    if missing:
        print("::error::not in the package index: " + " ".join(missing))
        return 1

    items.sort(key=lambda it: (version_key(it["octave"]), it["package"],
                               version_key(it["version"])))
    if LIMIT and len(items) > LIMIT:
        print(f"::warning::{len(items)} releases to harvest, "
              f"capped at {LIMIT}")
        items = items[:LIMIT]

    print(f"harvest {len(items)} releases; already held {held}, "
          f"before the oldest image {predating}, no Octave meets the declared "
          f"bounds {incompatible}, below Octave {MIN_OCTAVE} {below}, "
          f"not pkg-installable {uninstallable}, undated {undated}")

    # One image per shard: pulling is the expensive part, and an era measured
    # by one job is an era whose core record is written by one job too.
    by_era = {}
    for item in items:
        by_era.setdefault(item["octave"], []).append(item)

    include = []
    for octave in sorted(by_era, key=version_key):
        group = by_era[octave]
        # Enough shards to keep each one busy, and no more: every extra shard
        # pulls the era's image again for the sake of a release or two.
        count = min(SHARDS, -(-len(group) // PER_SHARD)) or 1
        print(f"  Octave {octave}: {len(group)} releases in {count} shard(s)")
        for ii in range(count):
            bucket = group[ii::count]
            if not bucket:
                continue
            include.append({
                "shard": f"{octave}-{ii + 1}",
                "octave": octave,
                "image": REPOSITORY + "@" + group[0]["digest"],
                "items": " ".join(f"{it['package']}@{it['version']}"
                                  for it in bucket)})

    with open(os.environ["GITHUB_OUTPUT"], "a") as fid:
        fid.write("matrix=" + json.dumps({"include": include}) + "\n")
        fid.write(f"count={len(items)}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
