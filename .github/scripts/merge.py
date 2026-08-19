#!/usr/bin/env python3
"""Fold this run's records into the data set and rebuild what is derived.

Records are stored one file per release, at data/<package>/<version>.json, and
a release once measured is never overwritten by a later run unless that run
measured the very same release again.  The archive therefore grows forwards:
every record describes a package as it actually was, built against the
dependencies that were actually current when it was measured.

The derived files -- the search index and the collision list -- describe the
ecosystem as it stands now, and so are built from the newest release of each
package only.
"""

import glob
import json
import os
import re

DATA = "data"
SAFE_VERSION = re.compile(r"^[A-Za-z0-9._+-]+$")

# The categories scan_functions reports, and the kind each entry is recorded
# under in the search index.
CATEGORIES = {
    "functions": "function",
    "namespaced_functions": "function",
    "scripts": "script",
    "classes": "class",
    "namespaced_classes": "class",
    "oldstyle_classes": "class",
    "method_extensions": "extension",
}


def load(path):
    with open(path) as fid:
        return json.load(fid)


def save(path, obj):
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    with open(path, "w") as fid:
        json.dump(obj, fid, sort_keys=True, separators=(",", ":"))
        fid.write("\n")


def store_incoming():
    """File each incoming record under its own package and version."""
    stored = 0
    for path in sorted(glob.glob(os.path.join("incoming", "*.json"))):
        record = load(path)
        package = record.get("package")
        version = record.get("version")
        if not package:
            print(f"::warning::{path}: no package name, ignored")
            continue
        if not version or not SAFE_VERSION.match(version):
            # A record that failed before it could learn its own version has
            # nowhere to live in a version keyed store.
            print(f"::warning::{package}: no usable version, ignored "
                  f"({record.get('status')}: {record.get('message', '')})")
            continue
        save(os.path.join(DATA, package, version + ".json"), record)
        stored += 1
    return stored


def all_records():
    """Every stored record, grouped by package."""
    byname = {}
    for path in sorted(glob.glob(os.path.join(DATA, "*", "*.json"))):
        record = load(path)
        byname.setdefault(record["package"], []).append(record)
    return byname


def newest_release(index, package, records):
    """The record for the package's newest release, or None if not held.

    The index says which release is newest; without it, fall back to the
    latest release date among the records held.
    """
    if index and package in index:
        versions = index[package].get("versions") or []
        if versions:
            wanted = versions[0].get("id")
            for record in records:
                if record.get("version") == wanted:
                    return record
            return None
    return max(records, key=lambda r: r.get("date") or "", default=None)


def release_order(record):
    """Releases in the order they were cut, oldest first."""
    return (record.get("date") or "", record.get("version") or "")


def core_history(byname):
    """What every package has taken over from core, release by release.

    Only packages that took something over in at least one held release are
    reported, but for those the whole series is, so that the release where a
    name was given up is as visible as the one where it was taken.

    The earliest held release of a package is a baseline, not an event: nothing
    before it was measured, so what it shadows cannot be said to have started
    there.  Changes are therefore reported only from the second release on.
    """
    history, changes = {}, []
    for package, records in sorted(byname.items()):
        series = []
        for record in sorted((r for r in records if r.get("status") == "ok"),
                             key=release_order):
            series.append({
                "version": record.get("version"),
                "date": record.get("date"),
                "shadows": sorted(record.get("core_shadowing") or []),
                "extends_types": sorted(record.get("core_type_extensions")
                                        or []),
            })
        if not any(s["shadows"] or s["extends_types"] for s in series):
            continue
        history[package] = series

        previous = None
        for entry in series:
            if previous is not None:
                for field, kind in (("shadows", "function"),
                                    ("extends_types", "type")):
                    was, now = set(previous[field]), set(entry[field])
                    for name in sorted(now - was):
                        changes.append({"package": package, "name": name,
                                        "kind": kind, "event": "added",
                                        "version": entry["version"],
                                        "date": entry["date"]})
                    for name in sorted(was - now):
                        changes.append({"package": package, "name": name,
                                        "kind": kind, "event": "removed",
                                        "version": entry["version"],
                                        "date": entry["date"]})
            previous = entry
    changes.sort(key=lambda c: (c["date"] or "", c["package"], c["name"]))
    return history, changes


def main():
    stored = store_incoming()

    index = None
    if os.path.exists("packages.json"):
        index = load("packages.json")
    else:
        print("::warning::packages.json absent; "
              "newest release inferred from record dates")

    byname = all_records()

    summary, latest = {}, {}
    for package, records in sorted(byname.items()):
        record = newest_release(index, package, records)
        summary[package] = {
            "latest": record.get("version") if record else None,
            "status": record.get("status") if record else "not-harvested",
            "sha256": record.get("sha256") if record else None,
            "date": record.get("date") if record else None,
            "message": record.get("message", "") if record else "",
            "releases": sorted(r["version"] for r in records),
        }
        if record is not None and record.get("status") == "ok":
            latest[package] = record

    save(os.path.join(DATA, "index.json"), summary)

    # The search index: one entry per name a package provides, plus the
    # methods and properties of every class, which are searchable but cannot
    # collide with a free function and so are marked as members.
    names = {}
    for package, record in sorted(latest.items()):
        contents = record.get("contents") or {}
        for category, kind in CATEGORIES.items():
            for item in contents.get(category) or []:
                names.setdefault(item["name"], []).append(
                    {"package": package, "kind": kind})
                for member in (item.get("methods") or []):
                    names.setdefault(item["name"] + "." + member, []).append(
                        {"package": package, "kind": "method"})
                for member in (item.get("properties") or []):
                    names.setdefault(item["name"] + "." + member, []).append(
                        {"package": package, "kind": "property"})

    save(os.path.join(DATA, "functions.json"), names)

    # Names more than one package puts on the load path.  Members are excluded:
    # two classes may share a method name without either shadowing anything.
    collisions = {
        name: providers for name, providers in names.items()
        if len({p["package"] for p in providers}) > 1
        and any(p["kind"] in ("function", "script", "class") for p in providers)
    }
    save(os.path.join(DATA, "collisions.json"), collisions)

    # What packages take over from core Octave.  The comparison itself is made
    # in the harvest container, where the load path before "pkg load" is
    # exactly core's and the built-ins can be asked for; this job only gathers
    # the answers.  Three views of the same facts, because the maintainer
    # asking "does my package do this" and the user asking "who replaced this
    # function" are looking for different things.
    shadowed, extended, packages = {}, {}, {}
    for package, record in sorted(latest.items()):
        shadows = sorted(record.get("core_shadowing") or [])
        extends = sorted(record.get("core_type_extensions") or [])
        for name in shadows:
            shadowed.setdefault(name, []).append(package)
        for name in extends:
            extended.setdefault(name, []).append(package)
        if shadows or extends:
            packages[package] = {"shadows": shadows,
                                 "extends_types": extends}

    history, changes = core_history(byname)

    save(os.path.join(DATA, "core_shadowing.json"),
         {"current": {"functions": shadowed, "types": extended,
                      "packages": packages},
          "history": history,
          "changes": changes})

    releases = sum(len(r) for r in byname.values())
    print(f"{stored} records stored this run; {releases} releases held across "
          f"{len(byname)} packages; {len(latest)} scanned at newest; "
          f"{len(names)} names; {len(collisions)} collisions")
    print(f"{len(packages)} packages take something over from core: "
          f"{len(shadowed)} core functions replaced, "
          f"{len(extended)} core types extended; "
          f"{len(history)} with a history, {len(changes)} changes recorded")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
