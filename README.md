# pkg-functions

Harvest what every package in [Octave Packages][index] actually provides, and
record it as data.

**Browse it: <https://pr0m1th3as.github.io/pkg-functions/>**

This is a prototype for [gnu-octave/packages#124][issue], the request to search
for individual function names within packages. It is **not an installable
Octave package** — it is CI infrastructure, cloned and run, plus a static
reader for what it produces.

[index]: https://gnu-octave.github.io/packages/
[issue]: https://github.com/gnu-octave/packages/issues/124

## Why it installs packages

The obvious source for a package's function list is its `INDEX` file, and it is
the wrong one. `INDEX` is a hand-curated documentation manifest: it says what a
maintainer chose to advertise. What matters here is what a package *puts on the
load path*, because that is what a user can call and what can shadow something
else. The two are not the same thing, and nothing but a real installation can
tell them apart:

- compiled functions do not exist until the package is built, so no reading of
  a source tarball can list them;
- a namespaced class resolves only when it is reachable — `NormalDistribution`
  is not a name, `prob.NormalDistribution` is;
- old-style `@class` directories are invisible to classdef reflection, and a
  `@dir` without a constructor is not a class at all but a set of methods
  grafted onto a type defined elsewhere;
- a `.m` file on the load path may be a script, which occupies a name but takes
  no arguments.

So each package is installed in a container, loaded, and measured. As a check
on the method: of the 458 names `statistics` 1.8.4 advertises in its own
`INDEX`, **every one is measured** — and three more besides, `gmdistribution`,
`qrandn` and `randsample`, which are on the load path and callable but were
never advertised. A measurement can be a superset of the manifest; it should
never be a subset.

## The chain

```
packages.json  ──▶  harvest_package  ──▶  package_paths  ──▶  scan_functions
   the index        install the           measure the          enumerate what
                    dependency closure    load path delta      the directories
                                                               provide
```

`package_paths` is the part that is easy to get wrong. `pkg load` pulls in
dependencies, so a single before-and-after difference credits a package with
everything they provide as well — loading `statistics` that way appears to add
520 names, 59 of which belong to `datatypes`. The whole dependency closure is
therefore unloaded and reloaded one package at a time, and each result is
cross-checked against the package's own installation directories. Anything
added from outside them is reported: a package that puts a foreign directory on
the load path is a defect worth seeing.

`scan_functions` sorts what it finds into plain functions, namespaced
functions, scripts, `classdef` classes, namespaced classes, old-style `@class`
classes, and `@dir` method extensions, with the public methods and properties
of every class. Hidden members are excluded deliberately: they are how a class
keeps an unimplemented method out of its documentation, and listing them here
would undo that.

## The data set

One file per release, and a release once measured is never overwritten:

```
data/statistics/1.8.4.json     what that release provided, as measured
data/statistics/1.8.3.json
data/__core__/11.3.0.json      core Octave, stored as one more provider
data/index.json                package → newest release, status, releases held
data/functions.json            name → what provides it, core Octave included
data/collisions.json           names two packages both answer to
data/core_shadowing.json       what packages take over from core, and when
data/dependencies.json         who depends on whom, declared and resolved
data/history.json              every release that ever carried each name
```

The first five are small enough to read in one go; `history.json` is not, at
1.7 MB, and is fetched only when something asks for one name's past.

The scheduled sweep harvests the **newest** release of each package, and
history accumulates forwards from the first run at no extra cost. Older
releases are harvested separately and deliberately, by a workflow of their own:
each is installed with its whole dependency closure resolved **as of the day it
shipped**, under the Octave that was current on that day. Resolving those
dependencies to today's versions would build a combination that never existed
and file it under a version that did, which is why it is a policy and not a
default — every record says which one produced it.

## How far back this reaches

Not as far as the ecosystem goes. This data set can only measure releases that
Octave Packages still lists, and the index is a forward-looking registry rather
than an archive.

The shape of what it remembers is stark. Of the releases it lists, **32 were
published between 2009 and 2018 — nine years — against 540 since 2022**. Eighty
seven of its 139 packages have their entire listed history starting in 2020 or
later, and 42 list exactly one release. `statistics` appears with 28 releases,
the earliest dated 2020-03-23; it did not begin in 2020, and neither did
`signal` (earliest listed 2019), `io` or `image` (2020). The tarballs that are
missing were mostly published under Octave Forge and are not reachable from
anything the index records.

The same gap shows from the other side: fourteen listed releases declare a
dependency whose earliest *listed* version is younger than the release itself —
`data-smoothing` 1.3.0, from 2012, requires `optim`, whose earliest listed
release is 2019. Those cannot be reconstructed at all, and are recorded as
failures naming the reason.

So read this as the ecosystem **as Octave Packages remembers it**: dense from
2019 onwards, thin before that, and silent on the decade before 2015 for which
no Octave container image exists either. A package's absence from a given year
here is evidence about the index, not about the package.

Every record carries the `sha256` of the release it describes, so a run whose
index reports an unchanged checksum skips the package without downloading
anything.

## What a package takes over from core

Each record also answers the question a search box cannot: what does loading
this package change about Octave itself?

`core_shadowing` lists the names the package puts on the load path that core
already answers to — built-in functions included, since a package overriding
`size` or `zeros` is the worst case there is. These are not coincidences.
`pkg load` **prepends** to the load path, so every name on that list is a core
function the package replaces for anyone who loads it.

`core_type_extensions` lists the core types the package grafts methods onto
through an `@dir` carrying no constructor. That shadows no name at all, but it
changes how a core type behaves for the rest of the session, which is worth
seeing separately rather than not at all.

Both are measured against a load path read before anything is installed or
loaded, and core is identified by the interpreter's own installation roots with
`site` directories excluded — so neither the current directory, nor a package
that happened to be loaded already, nor a local site install can be mistaken for
part of core.

`data/core_shadowing.json` gathers this across the ecosystem, in three views:

- `current` — what the newest release of each package takes over, indexed both
  by core name and by package;
- `history` — the whole series for every package that has ever taken something
  over, so the release where a name was *given up* is as visible as the one
  where it was taken;
- `changes` — each name entering or leaving, with the release and date it
  happened.

The earliest release held for a package is a baseline rather than an event:
nothing before it was measured, so what it shadows cannot be said to have
started there. Changes are reported from the second release on.

## The reader

[`site/`](site/) is a static page over that JSON — no build step, no server of
its own, and no dependency beyond the Bootstrap and Font Awesome that
[Octave Packages][index] and `pkg-octave-doc` already use, so it looks like the
rest of the ecosystem rather than like a separate thing. Five views: which
packages provide a name, what a package provides and builds on, the names two
packages both answer to, what packages take over from core, and when any of
that changed. Dependency trees and both timelines are drawn as plain SVG.

Published from the repository root by GitHub Pages. The entry point is
`index.html` at the root, so the site answers at the bare URL above rather than
at `/site/`, and the data stays at `data/` where everything else expects it —
the same shape [Octave Packages][index] uses. Publishing `/docs` instead would
serve the page and leave the data unreachable, since that source publishes only
that one folder.

## Running it

The `Harvest package functions` workflow runs twice daily and keeps up with
the present: it measures the newest release of each package and retries
whatever failed last time. `Harvest past package releases` is dispatched by
hand and does the other thing — it walks back through releases already
published, each under the Octave of its own day. Both take a list of package
names; for a first run, name a few rather than letting either loose on the
whole index.

Locally, against an already installed package:

```octave
addpath ('/path/to/pkg-functions');
[dirlist, depinfo] = package_paths ('statistics');
[json, S] = scan_functions (dirlist);
```

## What it does not do

- **Non-`pkg`-installable packages are absent.** Two of the 140 in the index
  declare no `pkg` dependency and cannot be installed by `pkg` at all. They are
  named in the run log rather than silently dropped.
- **A package that fails to build is recorded as having failed**, with the
  interpreter's own message, and retried on the next run. It is not dropped, so
  a package that needs a library the runner does not have appears as what it is
  rather than as a package that provides nothing.
- **The reader is a prototype, and where it belongs is still open.** It lives
  in [`site/`](site/) and is deliberately self-contained, so moving it to a
  repository of its own is a `git mv` and nothing more. Per the guidance in
  issue #124, that question is not settled by opening a pull request against
  the package index.
- **A namespace is not a name.** `+geom/` is a directory; only what is inside
  it is callable, so `geom.arclength` is recorded and `geom` is not. The reader
  will search a namespace, but the data set does not invent an entry for one.

## Licence

GPL v3 or later. See [COPYING](COPYING).
