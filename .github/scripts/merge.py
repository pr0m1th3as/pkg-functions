#!/usr/bin/env python3
"""Fold this run's records into the data set and rebuild what is derived.

Records are stored one file per release, at data/<package>/<version>.json, and
a release once measured is never overwritten by a later run unless that run
measured the very same release again.  The archive therefore grows forwards:
every record describes a package as it actually was.

Core Octave is stored the same way, under data/__core__/<octave version>.json.
It is not fixed either -- functions enter and leave it between releases -- so a
package can begin shadowing a core function without changing at all.  Treating
core as one more provider is what lets that be attributed to core rather than
silently blamed on the package.

Nothing about collisions or shadowing is re-measured here.  Each record already
holds the complete list of names its release puts on the load path, so both
questions are answered by intersecting stored lists, and both can be answered
again for a core release that came later than the package release it is
compared against.
"""

import glob
import json
import os
import re

DATA = "data"
CORE = "__core__"
IMAGES = os.path.join(".github", "octave-images.json")
SAFE_VERSION = re.compile(r"^[A-Za-z0-9._+-]+$")

# The categories scan_functions reports, and the kind each entry is recorded
# under in the search index.
CATEGORIES = {
    "functions": "function",
    "namespaced_functions": "namespace function",
    "scripts": "script",
    "classes": "class",
    "namespaced_classes": "namespace class",
    "oldstyle_classes": "class",
    "method_extensions": "extension",
}

# Those of them that occupy a name on the load path, and so can collide.  A
# method extension is excluded: it adds methods to a type named elsewhere.
LOAD_PATH_CATEGORIES = ("functions", "namespaced_functions", "scripts",
                        "classes", "namespaced_classes", "oldstyle_classes")

# The kinds those categories produce.  A method or a property is reachable only
# through an object of its own class and contends with nothing, but a
# namespaced function occupies "ns.name" on the load path as surely as a plain
# one occupies "name".
CONTENDING = ("function", "script", "class", "namespace function",
              "namespace class")


def load(path):
    with open(path) as fid:
        return json.load(fid)


def save(path, obj):
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    with open(path, "w") as fid:
        json.dump(obj, fid, sort_keys=True, separators=(",", ":"))
        fid.write("\n")


DEPENDENCY = re.compile(r"^\s*([A-Za-z0-9_.+-]+)\s*(?:\(\s*([^)]*?)\s*\))?\s*$")


def declared_dependencies(index, package, version):
    """What a release names as dependencies, and the least it will accept.

    The index is the only place a *direct* dependency is recorded, and the only
    place the version constraint is recorded at all: a record says which
    version was installed, never which one was asked for.  Both are worth
    having side by side, because they are usually not the same number -- a
    package that declares ">= 1.2.6" is routinely built against something much
    newer, and that gap is the interesting part.
    """
    for release in (index.get(package, {}).get("versions") or []):
        if release.get("id") != version:
            continue
        names, requires = [], {}
        for dep in release.get("depends") or []:
            if isinstance(dep, dict):
                name = dep.get("name")
                wants = " ".join(x for x in (dep.get("operator"),
                                             dep.get("version")) if x)
            else:
                found = DEPENDENCY.match(str(dep))
                if not found:
                    continue
                name, wants = found.group(1), (found.group(2) or "")
            if name and name not in ("octave", "pkg"):
                names.append(name)
                requires[name] = wants
        return names, requires
    return [], {}


def dependency_view(index, byname):
    """Who depends on whom, release by release, and what that resolved to."""
    packages, dependents = {}, {}
    for package, records in sorted(byname.items()):
        if package == CORE:
            continue
        series = []
        for record in sorted((r for r in records if r.get("status") == "ok"),
                             key=release_order):
            version = record.get("version")
            declares, requires = declared_dependencies(index, package,
                                                       version)
            resolved = {d["name"]: d["version"]
                        for d in (record.get("dependencies") or [])}
            series.append({"version": version, "date": record.get("date"),
                           "octave": record.get("octave"),
                           "declares": declares, "requires": requires,
                           "resolved": resolved})
            for name in declares:
                dependents.setdefault(name, set()).add(package)
        if series:
            packages[package] = series
    return {"packages": packages,
            "dependents": {k: sorted(v) for k, v in sorted(dependents.items())}}


def name_history(byname, index):
    """Every release that ever provided each name, reduced to its span.

    Built from the stored records rather than from the current index, which is
    the whole point: a name that left a package years ago is still a fact about
    that package, and nothing else records it.  Core Octave is one more
    provider here, so a function's whole story -- who carried it, when it
    entered core and when it left -- reads in one place.
    """
    out = {}
    for provider, records in byname.items():
        for record in sorted((r for r in records if r.get("status") == "ok"),
                             key=release_order):
            version, date = record.get("version"), record.get("date")
            for name in sorted(load_path_names(record)):
                seen = out.setdefault(name, {}).setdefault(provider, {})
                seen.setdefault("first", version)
                seen.setdefault("from", date)
                seen["last"], seen["to"] = version, date
                seen["count"] = seen.get("count", 0) + 1
            # Members are carried too: "history of a method" is a fair question
            # and the records answer it.
            contents = record.get("contents") or {}
            for category in CATEGORIES:
                for item in contents.get(category) or []:
                    for member in ((item.get("methods") or [])
                                   + (item.get("properties") or [])):
                        full = item["name"] + "." + member
                        seen = out.setdefault(full, {}).setdefault(provider, {})
                        seen.setdefault("first", version)
                        seen.setdefault("from", date)
                        seen["last"], seen["to"] = version, date
                        seen["count"] = seen.get("count", 0) + 1
    return out


def octave_release_dates():
    """The day each Octave release was published, by version.

    Empty when the table is absent, which leaves every record dated as it was
    measured -- the behaviour before there was a table to consult.
    """
    try:
        with open(IMAGES) as fid:
            table = json.load(fid)
    except (OSError, ValueError):
        return {}
    return {r["version"]: r["date"] for r in table.get("releases") or []
            if r.get("version") and r.get("date")}


def store_incoming():
    """File each incoming record under its own provider and version."""
    release_dates = octave_release_dates()
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
        if package == CORE and version in release_dates:
            # A core record is stamped with the day it was measured: today for
            # the scheduled sweep, the day being reconstructed for a historical
            # one.  Neither is the day that core became the ecosystem's core,
            # and the timeline wants that one -- dated by its release, a core
            # sits ahead of every package published after it however late it
            # came to be measured, and it stops moving every time it is
            # measured again.
            record["date"] = release_dates[version]
        save(os.path.join(DATA, package, version + ".json"), record)
        stored += 1
    return stored


def all_records():
    """Every stored record, grouped by provider."""
    byname = {}
    for path in sorted(glob.glob(os.path.join(DATA, "*", "*.json"))):
        record = load(path)
        byname.setdefault(record["package"], []).append(record)
    return byname


def load_path_names(record):
    """The names a release puts on the load path.

    Core records carry a plain name list; package records carry the categorised
    scan the names have to be read out of.  Methods and properties are left out
    of both: they are reachable only through an object of their own class, so
    they cannot collide with a function.
    """
    if record.get("package") == CORE:
        return set(record.get("names") or [])
    contents = record.get("contents") or {}
    names = set()
    for category in LOAD_PATH_CATEGORIES:
        for item in contents.get(category) or []:
            names.add(item["name"])
    return names


def extension_names(record):
    """The types an "@dir" without a constructor adds methods to."""
    contents = record.get("contents") or {}
    return {item["name"] for item in contents.get("method_extensions") or []}


def version_key(version):
    """Order version strings numerically, so 9.4.0 comes before 11.3.0.

    A plain string sort puts 9.4.0 last.  For a package that is only untidy,
    but for core it decides which release is the current one, and so what every
    package in the set is judged to shadow.  Each part is tagged with its type
    so that a numeric part is never compared against a word.
    """
    parts = re.split(r"[._+-]", version or "")
    return tuple((0, int(p), "") if p.isdigit() else (1, 0, p) for p in parts)


def release_order(record):
    """Releases in the order they were cut, oldest first."""
    return (record.get("date") or "", version_key(record.get("version")))


def newest_release(index, package, records):
    """The record for the provider's newest release, or None if not held."""
    if index and package in index:
        versions = index[package].get("versions") or []
        if versions:
            wanted = versions[0].get("id")
            for record in records:
                if record.get("version") == wanted:
                    return record
            return None
    return max(records, key=release_order, default=None)


def name_providers(state):
    """Which packages provide each name, core excluded."""
    providers = {}
    for package, names in state.items():
        if package == CORE:
            continue
        for name in names:
            providers.setdefault(name, set()).add(package)
    return providers


def derive(state):
    """The two views: names provided twice over, and names core also answers to.

    Neither is measured.  Both fall out of the stored name lists, which is what
    lets a package release be compared against a core release it was never run
    against.
    """
    core = state.get(CORE, set())
    providers = name_providers(state)
    collisions = {n for n, p in providers.items() if len(p) > 1}
    shadowing = {(p, n) for p, names in state.items() if p != CORE
                 for n in (names & core)}
    return collisions, shadowing


def timeline(byname):
    """Walk every release in date order, deriving what each one changed.

    At any point the state is one name set per provider.  Applying a release
    replaces that provider's set, and whatever the derived views gain or lose
    as a result is attributed to that release -- which is how a name that
    starts being shadowed because *core* gained it is told apart from one that
    starts being shadowed because the package gained it.
    """
    events = []
    for provider, records in byname.items():
        for record in records:
            if record.get("status") != "ok":
                continue
            events.append({"provider": provider,
                           "version": record.get("version"),
                           "date": record.get("date") or "",
                           "names": load_path_names(record),
                           "extensions": extension_names(record)})
    events.sort(key=lambda e: (e["date"], e["provider"],
                               version_key(e["version"])))

    # Core is the one provider whose order is its version, not the day it was
    # measured.  Every record carries the date of its harvest, so running a
    # sweep under an older image writes a record for a core release that came
    # *before* the one already held, dated today -- and replayed by date it
    # would be applied last, become the current core, and silently re-derive
    # every package's shadowing against an interpreter nobody is running.  An
    # older core measured late is a fact about that release, not a change to
    # what core is now: the record is kept, and it is its own baseline if it is
    # the first core held, but it never displaces a newer one.
    kept, highest = [], None
    for event in events:
        if event["provider"] == CORE:
            key = version_key(event["version"])
            if highest is not None and key <= highest:
                continue
            highest = key
        kept.append(event)
    events = kept

    # The earliest release held for each provider is a baseline, not an event.
    # The first sweep records every package's *current* release carrying its
    # own release date, some of them years old; replaying those in date order
    # would report collisions as having appeared on dates when nothing was
    # observed at all.  Baselines are applied first and silently, so what the
    # changes describe is the evolution from the day measurement began.
    seen = set()
    baseline, subsequent = [], []
    for event in events:
        if event["provider"] not in seen:
            seen.add(event["provider"])
            baseline.append(event)
        else:
            subsequent.append(event)

    state, extensions = {}, {}
    for event in baseline:
        state[event["provider"]] = event["names"]
        extensions[event["provider"]] = event["extensions"]
    collisions_before, shadowing_before = derive(state)
    collision_changes, shadowing_changes = [], []

    for event in subsequent:
        state[event["provider"]] = event["names"]
        extensions[event["provider"]] = event["extensions"]
        collisions_now, shadowing_now = derive(state)
        providers = name_providers(state)

        cause = {"provider": event["provider"], "version": event["version"],
                 "date": event["date"]}
        for name in sorted(collisions_now - collisions_before):
            collision_changes.append({
                "name": name, "event": "added", "triggered_by": cause,
                "providers": sorted(providers[name])})
        for name in sorted(collisions_before - collisions_now):
            collision_changes.append({
                "name": name, "event": "removed", "triggered_by": cause,
                "providers": sorted(providers.get(name, []))})
        for package, name in sorted(shadowing_now - shadowing_before):
            shadowing_changes.append({
                "package": package, "name": name, "event": "added",
                "triggered_by": cause})
        for package, name in sorted(shadowing_before - shadowing_now):
            shadowing_changes.append({
                "package": package, "name": name, "event": "removed",
                "triggered_by": cause})

        collisions_before, shadowing_before = collisions_now, shadowing_now

    return collision_changes, shadowing_changes, state, extensions


def main():
    stored = store_incoming()

    index = None
    if os.path.exists("packages.json"):
        index = load("packages.json")
    else:
        print("::warning::packages.json absent; "
              "newest release inferred from record dates")

    byname = all_records()
    core_records = byname.get(CORE, [])

    summary, latest = {}, {}
    for package, records in sorted(byname.items()):
        if package == CORE:
            continue
        record = newest_release(index, package, records)
        summary[package] = {
            "latest": record.get("version") if record else None,
            "status": record.get("status") if record else "not-harvested",
            "sha256": record.get("sha256") if record else None,
            "date": record.get("date") if record else None,
            "message": record.get("message", "") if record else "",
            "releases": sorted((r["version"] for r in records),
                               key=version_key),
        }
        if record is not None and record.get("status") == "ok":
            latest[package] = record

    save(os.path.join(DATA, "index.json"), summary)

    # The search index: one entry per name a package provides, plus the methods
    # and properties of every class, which are searchable but cannot collide
    # with a free function and so are marked as members.
    # Keyed by the whole name the load path answers to, never by part of one.
    # A namespaced function is "ns.name" and contends only with the same
    # "ns.name": +dxf/mean.m and +dfg/mean.m are two different functions and
    # must never be reported as one, while two packages both shipping
    # +dxf/mean.m genuinely are in each other's way.
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

    # Core Octave answers to names too, and a reader looking one up should be
    # told so.  It is a provider in this index and nowhere else: the collision
    # view below counts packages contending with each other, which is a
    # different question from a package replacing core, and that one has a view
    # of its own.
    core_now = newest_release(None, CORE, byname.get(CORE, []))
    if core_now:
        for name in (core_now.get("names") or []):
            names.setdefault(name, []).append({"package": CORE, "kind": "core"})

    save(os.path.join(DATA, "functions.json"), names)
    save(os.path.join(DATA, "history.json"), name_history(byname, index))

    # Who depends on whom, which no other file answers: index.json carries no
    # dependencies at all, and a record's closure is flattened.
    save(os.path.join(DATA, "dependencies.json"), dependency_view(index or {},
                                                                 byname))

    (collision_changes, shadowing_changes,
     final_state, final_extensions) = timeline(byname)

    # Names more than one package puts on the load path, as things stand.
    current_collisions = {
        name: [p for p in providers if p["package"] != CORE]
        for name, providers in names.items()
        if len({p["package"] for p in providers if p["package"] != CORE}) > 1
        and any(p["kind"] in CONTENDING for p in providers)
    }
    save(os.path.join(DATA, "collisions.json"),
         {"current": current_collisions, "changes": collision_changes})

    # What packages take over from core.  The per-release measurement is kept
    # as recorded, and the changes come from the timeline, so a change caused by
    # a core release is attributed to core rather than to the package.
    # Derived from where the timeline ends, not from what each harvest measured.
    # A release measured against an older core recorded no shadowing for a name
    # core has since gained; taking the harvest-time value here would leave this
    # view contradicting the changes below, which is the very confusion this
    # whole section exists to remove.
    # The timeline leaves core at its highest version held, not at whichever
    # record was written most recently, so this is the newest core measured.
    core_now = final_state.get(CORE, set())
    shadowed, extended, packages = {}, {}, {}
    for package in sorted(p for p in final_state if p != CORE):
        shadows = sorted(final_state[package] & core_now)
        extends = sorted(final_extensions.get(package, set()) & core_now)
        for name in shadows:
            shadowed.setdefault(name, []).append(package)
        for name in extends:
            extended.setdefault(name, []).append(package)
        if shadows or extends:
            packages[package] = {"shadows": shadows, "extends_types": extends}

    history = {}
    for package, records in sorted(byname.items()):
        if package == CORE:
            continue
        series = [{"version": r.get("version"), "date": r.get("date"),
                   "octave": r.get("octave"),
                   "shadows": sorted(r.get("core_shadowing") or []),
                   "extends_types": sorted(r.get("core_type_extensions") or [])}
                  for r in sorted((x for x in records
                                   if x.get("status") == "ok"),
                                  key=release_order)]
        if any(s["shadows"] or s["extends_types"] for s in series):
            history[package] = series

    save(os.path.join(DATA, "core_shadowing.json"),
         {"current": {"functions": shadowed, "types": extended,
                      "packages": packages},
          "core_releases": sorted((r["version"] for r in core_records),
                                  key=version_key),
          # The day each of those became current, so a reader can place a
          # change against what core was doing without opening every record.
          "core_dates": {r["version"]: r.get("date")
                         for r in core_records if r.get("date")},
          "history": history,
          "changes": shadowing_changes})

    releases = sum(len(r) for r in byname.values() if r is not core_records)
    print(f"{stored} records stored this run; {releases} package releases held "
          f"across {len(summary)} packages; {len(latest)} scanned at newest; "
          f"{len(names)} names")
    print(f"{len(current_collisions)} collisions now, "
          f"{len(collision_changes)} collision changes on record; "
          f"{len(packages)} packages take something over from core, "
          f"{len(shadowing_changes)} shadowing changes on record; "
          f"core releases held: {len(core_records)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
