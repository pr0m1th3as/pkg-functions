# The reader

A static page over the harvested data set. Its entry point is `index.html` at
the repository root — so the site answers at `/pkg-functions/` rather than
`/pkg-functions/site/`, the way Octave Packages does — and everything it draws
with lives here. It fetches the derived files at `data/` and asks for a single
release record only when someone opens one.

The look is the one Octave Packages and `pkg-octave-doc` use: Bootstrap 5.1.0
and Font Awesome 5.15.4, from the same CDNs and at the same versions those
pages pin, so a reader moving between them does not notice a seam. Everything
this page draws itself — dependency trees, the change timeline — is plain SVG.
A chart library would weigh more than the rest of the repository put together.

## Running it

Anything that serves the repository root will do, because the page reaches the
data by a relative path:

```bash
python3 -m http.server 8000        # from the repository root
# then open http://127.0.0.1:8000/
```

Opening `index.html` off disk does not work: `fetch` refuses a `file://`
request for the JSON beside it.

## Publishing it

GitHub Pages, serving from the **repository root** rather than `/docs`.
`/docs` publishes that folder alone, which would leave `data/` unreachable and
the page loading for ever; the data would have to move inside it, and the data
set is the point of this repository rather than an asset of its website.

## The five views

| View | Answers |
|------|---------|
| Search | which packages provide a name, and whether core does too |
| Packages | what depends on what; per package, its dependency tree and how its dependencies moved release by release |
| Collisions | the names more than one package answers to, grouped by who is contesting |
| Core | what each package takes over from the interpreter |
| Timeline | when shadowing started and stopped, and which release caused it |

The timeline is the one to show first. The tall column in April 2018 is Octave
4.4.0 handing the statistics functions to the package that carries them now,
and it was drawn from measurements rather than from anybody's memory.

## Searching

| Typed | Means |
|-------|-------|
| `mean` | anything containing it, exact names first |
| `"mean"` | that name exactly — `BaseArray.mean` yes, `anova.groupmeans` no |
| `+geom` | everything the `geom` namespace holds, nesting included |

Core Octave is one of the providers, so a name no package carries is still
found. Clicking any name opens what has answered to it over time — every
measured release of every package, core included.

A quoted query matches any dot-separated part of a name, because either part is
something a reader looks for: `"datetime"` finds the class and all 102 names it
provides. The two switches put class methods and class properties away; they
outnumber everything else four to one.
