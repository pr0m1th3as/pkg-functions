/* pkg-functions -- a reader for the harvested data set.
 *
 * The five derived files are small enough to hold at once; the 654 per-release
 * records are not, at 7.4 MB, so a record is fetched only when someone opens
 * it.  Bootstrap carries the chrome, and everything this file draws itself --
 * dependency trees, the change timeline -- is plain SVG, because a chart
 * library would be a heavier dependency than the whole rest of the repository.
 */

'use strict';

var DATA = '../data/';
var db = {};

var CORE = '__core__';

var VIEWS = [
  ['search', 'Search'],
  ['packages', 'Packages'],
  ['collisions', 'Collisions'],
  ['core', 'Core'],
  ['timeline', 'Timeline']
];

/* ------------------------------------------------------------------ helpers */

function el (tag, attrs, kids) {
  var node = document.createElement (tag);
  apply (node, attrs, kids);
  return node;
}

function svg (tag, attrs, kids) {
  var node = document.createElementNS ('http://www.w3.org/2000/svg', tag);
  apply (node, attrs, kids);
  return node;
}

function apply (node, attrs, kids) {
  for (var key in (attrs || {})) {
    if (key === 'class') node.setAttribute ('class', attrs[key]);
    else if (key === 'text') node.textContent = attrs[key];
    else if (key === 'html') node.innerHTML = attrs[key];
    else node.setAttribute (key, attrs[key]);
  }
  (kids || []).forEach (function (kid) {
    node.appendChild (typeof kid === 'string'
                      ? document.createTextNode (kid) : kid);
  });
}

/* A Bootstrap card, which is the unit every view is built from. */
function card (title, lede, body) {
  var head = el ('div', {class: 'card-header card-header-mod'});
  head.appendChild (el ('h5', {class: 'mb-0', text: title}));
  if (lede) head.appendChild (el ('p', {class: 'mb-0 mt-1 text-muted small',
                                        text: lede}));
  var inner = el ('div', {class: 'card-body'});
  (Array.isArray (body) ? body : [body]).forEach (function (b) {
    if (b) inner.appendChild (b);
  });
  return el ('div', {class: 'card rounded mb-4'}, [head, inner]);
}

function pkgLink (name, extra) {
  return el ('a', {class: extra || 'badge bg-light text-dark border',
                   href: '#/packages/' + encodeURIComponent (name),
                   text: name});
}

function route () {
  var raw = (location.hash || '#/search').replace (/^#\/?/, '');
  var query = '';
  var mark = raw.indexOf ('?');
  if (mark >= 0) { query = raw.slice (mark + 1); raw = raw.slice (0, mark); }
  var parts = raw.split ('/');
  return {view: parts[0] || 'search',
          arg: parts[1] ? decodeURIComponent (parts[1]) : '',
          query: query};
}

function days (date) {
  var p = (date || '1970-01-01').split ('-');
  return Date.UTC (+p[0], +p[1] - 1, +p[2]) / 86400000;
}

/* --------------------------------------------------------------------- data */

function load () {
  var files = ['index', 'functions', 'collisions', 'core_shadowing',
               'dependencies'];
  return Promise.all (files.map (function (name) {
    return fetch (DATA + name + '.json').then (function (r) {
      if (! r.ok) throw new Error (name + ': ' + r.status);
      return r.json ();
    });
  })).then (function (all) {
    db.index = all[0];
    db.names = all[1];
    db.collisions = all[2];
    db.core = all[3];
    db.deps = all[4];
    db.sorted = Object.keys (db.names).sort (function (a, b) {
      return a.toLowerCase () < b.toLowerCase () ? -1 : 1;
    });
    db.shadowed = db.core.current.functions || {};

    /* Which dotted prefixes are namespaces rather than classes.  A namespaced
       entry proves its own prefixes: "arduinoio.config.config_due" says both
       "arduinoio" and "arduinoio.config" are namespaces.  Nothing else can be
       asked this, because the load path carries no name for a namespace -- it
       is a directory, and only what is inside it is callable. */
    db.namespaces = {};
    Object.keys (db.names).forEach (function (name) {
      var isNamespaced = db.names[name].some (function (p) {
        return p.kind === 'namespace function' || p.kind === 'namespace class';
      });
      if (! isNamespaced) return;
      var parts = name.toLowerCase ().split ('.');
      for (var ii = 1; ii < parts.length; ii++) {
        db.namespaces[parts.slice (0, ii).join ('.')] = true;
      }
    });
  });
}

/* ------------------------------------------------------------------- search */

function viewSearch (arg, query) {
  var initial = decodeURIComponent ((/q=([^&]*)/.exec (query) || [, ''])[1]);
  var box = el ('input', {type: 'search', class: 'form-control mono',
    placeholder: 'mean · "mean" for that name exactly · +geom for a namespace',
    value: initial, autofocus: 'autofocus', 'aria-label': 'search names'});

  /* Methods and properties outnumber everything else four to one, and someone
     asking who provides "mean" rarely wants every distribution class that has
     a mean method.  They stay on by default -- hiding data by default would be
     the worse surprise -- but they can be put away. */
  var toggles = el ('div', {class: 'mt-2'});
  var switches = {};
  [['method', 'class methods'], ['property', 'class properties']]
    .forEach (function (pair) {
      var id = 'show-' + pair[0];
      var input = el ('input', {class: 'form-check-input', type: 'checkbox',
                                id: id, checked: 'checked', role: 'switch'});
      switches[pair[0]] = input;
      toggles.appendChild (el ('div',
        {class: 'form-check form-switch d-inline-block me-4'}, [input,
          el ('label', {class: 'form-check-label small', for: id,
                        text: pair[1]})]));
    });

  var count = el ('p', {class: 'text-muted small mt-2 mb-2'});
  var table = el ('table', {class: 'table table-sm table-hover tight mb-0'});
  var tbody = el ('tbody');
  table.appendChild (tbody);

  function wanted (name) {
    var kinds = (db.names[name] || []).map (function (p) { return p.kind; });
    return kinds.some (function (k) {
      if (k === 'method') return switches.method.checked;
      if (k === 'property') return switches.property.checked;
      return true;
    });
  }

  function draw () {
    var raw = box.value.trim ();
    tbody.textContent = '';
    if (! raw) { count.textContent = ''; return; }

    /* "+geom" is everything the geom namespace holds.  Spelled the way Octave
       spells it on disk, and answerable only because a namespaced entry is now
       a kind of its own: a class would otherwise be indistinguishable from a
       namespace, and "+BaseArray" would quietly list its methods. */
    if (raw.charAt (0) === '+') {
      return drawNamespace (raw.slice (1).replace (/\/+$/, ''));
    }

    /* A quoted query is that name and nothing else, which is the only way to
       ask for "mean" without also being told about nanmean and trimmean. */
    var quoted = raw.length > 1 && raw.charAt (0) === '"'
                 && raw.charAt (raw.length - 1) === '"';
    var q = (quoted ? raw.slice (1, -1) : raw).toLowerCase ();
    if (! q) { count.textContent = ''; return; }

    /* A qualified name is matched on any of its parts, because either part is
       something a reader might be looking for.  "mean" finds BaseArray.mean,
       whose method is called mean, but not anova.groupmeans, whose method is
       called groupmeans and merely contains the word; "datetime" finds the
       datetime class and everything datetime provides. */
    var exact = [], starts = [], holds = [];
    for (var ii = 0; ii < db.sorted.length; ii++) {
      var name = db.sorted[ii], low = name.toLowerCase ();
      var parts = low.split ('.');
      if (low === q || parts.indexOf (q) >= 0) exact.push (name);
      else if (quoted) continue;
      else if (low.indexOf (q) === 0) starts.push (name);
      else if (low.indexOf (q) > 0) holds.push (name);
    }
    var hits = exact.concat (starts, holds).filter (wanted);

    count.textContent = hits.length + (quoted ? ' exact match' : ' name')
      + (hits.length === 1 ? '' : (quoted ? 'es' : 's'))
      + (hits.length > 200 ? ' — showing the first 200' : '');
    if (! hits.length) {
      tbody.appendChild (el ('tr', {}, [el ('td', {class: 'text-muted',
        text: quoted ? 'No package provides exactly that name.'
                     : 'Nothing provides that.'})]));
      return;
    }
    hits.slice (0, 200).forEach (function (name) {
      tbody.appendChild (nameRow (name));
    });
  }

  function drawNamespace (asTyped) {
    /* Matched without regard to case, but reported back as it was typed:
       telling someone there is no namespace called "basearray" when they asked
       about BaseArray reads like our mistake rather than an answer. */
    var ns = asTyped.toLowerCase ();
    if (! ns || ! db.namespaces[ns]) {
      count.textContent = '';
      tbody.appendChild (el ('tr', {}, [el ('td', {class: 'text-muted',
        text: ns ? 'No package provides a namespace called ' + asTyped + '.'
                 : 'Name a namespace after the plus, as in +geom.'})]));
      return;
    }
    var prefix = ns + '.';
    var hits = db.sorted.filter (function (name) {
      return name.toLowerCase ().indexOf (prefix) === 0;
    }).filter (wanted);
    count.textContent = hits.length + ' name' + (hits.length === 1 ? '' : 's')
      + ' in the ' + asTyped + ' namespace'
      + (hits.length > 200 ? ' — showing the first 200' : '');
    hits.slice (0, 200).forEach (function (name) {
      tbody.appendChild (nameRow (name));
    });
  }

  box.addEventListener ('input', draw);
  Object.keys (switches).forEach (function (k) {
    switches[k].addEventListener ('change', draw);
  });
  draw ();

  return card ('Every name every package provides',
    'Measured by installing each release and reading what it actually adds to '
    + 'the load path, not by reading what it declares. ' + db.sorted.length
    + ' names across ' + Object.keys (db.index).length + ' packages — '
    + 'functions, scripts and classes, and the methods and properties of every '
    + 'class.',
    [box, toggles, count, table]);
}

function nameRow (name) {
  var providers = db.names[name] || [];
  var kinds = {}, packages = {}, inCore = false;
  providers.forEach (function (p) {
    if (p.package === CORE) { inCore = true; return; }
    kinds[p.kind] = true;
    packages[p.package] = true;
  });

  var left = el ('td', {style: 'width: 40%'});
  left.appendChild (el ('a', {class: 'mono text-decoration-none',
    href: '#/name/' + encodeURIComponent (name), text: name}));
  if (Object.keys (kinds).length) {
    left.appendChild (el ('span', {class: 'text-muted small ms-2',
                                   text: Object.keys (kinds).join (', ')}));
  }

  var right = el ('td');
  var grid = el ('div', {class: 'namegrid'});
  /* Core is not a package contending with the others; it is the floor they
     stand on, so it is shown but never counted as a clash. */
  var clash = Object.keys (packages).length > 1;
  Object.keys (packages).sort ().forEach (function (pkg) {
    grid.appendChild (pkgLink (pkg, 'badge border text-decoration-none '
      + (clash ? 'bg-warning text-dark' : 'bg-light text-dark')));
  });
  if (inCore) {
    grid.appendChild (el ('span', {class: 'badge bg-purple text-white',
                                   text: 'core Octave'}));
  }
  right.appendChild (grid);
  return el ('tr', {}, [left, right]);
}

/* ---------------------------------------------------------- one name's life */

/* The history is a megabyte and a half and most visits never ask for it, so it
   is fetched the first time somebody does and kept thereafter. */
function withHistory (then) {
  if (db.history) { then (); return; }
  fetch (DATA + 'history.json').then (function (r) {
    if (! r.ok) throw new Error ('history: ' + r.status);
    return r.json ();
  }).then (function (h) { db.history = h; then (); })
    .catch (function (err) { db.history = {}; db.historyError = err.message;
                             then (); });
}

function viewName (name) {
  var providers = db.names[name] || [];
  var here = el ('div');
  var kinds = {};
  providers.forEach (function (p) {
    if (p.package !== CORE) kinds[p.kind] = true;
  });

  var now = el ('div', {class: 'namegrid'});
  providers.forEach (function (p) {
    now.appendChild (p.package === CORE
      ? el ('span', {class: 'badge bg-purple text-white', text: 'core Octave'})
      : pkgLink (p.package, 'badge bg-light text-dark border text-decoration-none'));
  });
  if (! providers.length) {
    now.appendChild (el ('span', {class: 'text-muted',
      text: 'Nothing provides this today.'}));
  }
  here.appendChild (card (name,
    (Object.keys (kinds).join (', ') || 'core Octave')
    + ' — what answers to this name now', now));

  var holder = el ('div');
  here.appendChild (holder);
  withHistory (function () {
    holder.textContent = '';
    holder.appendChild (historyCard (name));
  });
  return here;
}

function historyCard (name) {
  var story = (db.history || {})[name];
  if (! story) {
    return card ('Where it has been', null, el ('p', {class: 'mb-0 text-muted',
      text: db.historyError
        ? 'The history could not be loaded: ' + db.historyError
        : 'No release on record ever provided this name.'}));
  }
  var rows = el ('tbody');
  Object.keys (story).sort (function (a, b) {
    return (story[a].from || '') < (story[b].from || '') ? -1 : 1;
  }).forEach (function (who) {
    var span = story[who];
    var label = who === CORE
      ? el ('span', {class: 'badge bg-purple text-white', text: 'core Octave'})
      : pkgLink (who, 'badge bg-light text-dark border text-decoration-none');
    rows.appendChild (el ('tr', {}, [
      el ('td', {}, [label]),
      el ('td', {class: 'mono', text: span.first + '  …  ' + span.last}),
      el ('td', {class: 'text-muted small',
                 text: (span.from || '?') + ' to ' + (span.to || '?')}),
      el ('td', {class: 'text-muted small',
                 text: span.count + ' release' + (span.count === 1 ? '' : 's')})
    ]));
  });
  var table = el ('table', {class: 'table table-sm tight mb-0'}, [
    el ('thead', {}, [el ('tr', {}, [
      el ('th', {text: 'provided by'}), el ('th', {text: 'from … to'}),
      el ('th', {text: 'dates'}), el ('th', {text: 'in'})])]), rows]);
  return card ('Where it has been',
    'Every measured release that carried this name, core Octave included. '
    + 'A span that ends before today is a name that was dropped.', table);
}

/* ----------------------------------------------------------------- packages */

/* The dependency graph, as the ecosystem stands. */
function viewPackages (arg) {
  if (arg) return viewPackage (arg);

  var dependents = db.deps.dependents;
  var rows = el ('tbody');
  Object.keys (dependents).sort (function (a, b) {
    return dependents[b].length - dependents[a].length;
  }).forEach (function (name) {
    var who = el ('div', {class: 'namegrid'});
    dependents[name].forEach (function (d) { who.appendChild (pkgLink (d,
      'badge bg-light text-dark border text-decoration-none')); });
    rows.appendChild (el ('tr', {}, [
      el ('td', {class: 'mono'}, [pkgLink (name, 'text-decoration-none mono')]),
      el ('td', {class: 'text-muted small', text: dependents[name].length}),
      el ('td', {}, [who])]));
  });
  var table = el ('table', {class: 'table table-sm table-hover tight mb-0'}, [
    el ('thead', {}, [el ('tr', {}, [
      el ('th', {text: 'depended upon'}), el ('th', {text: 'by'}),
      el ('th', {text: 'which packages'})])]),
    rows]);

  var all = el ('div', {class: 'namegrid'});
  Object.keys (db.index).sort ().forEach (function (name) {
    var info = db.index[name];
    all.appendChild (pkgLink (name, 'badge border text-decoration-none '
      + (info.status === 'ok' ? 'bg-light text-dark' : 'bg-white text-muted')));
  });

  return el ('div', {}, [
    card ('What depends on what',
      'Only a package another package builds on appears here. Everything else '
      + 'in the ecosystem stands alone, which is itself worth knowing.',
      table),
    card ('Every package',
      Object.keys (db.index).length + ' in the index. A greyed name is one no '
      + 'release of which could be installed and measured.',
      all)]);
}

/* One package: its tree, what leans on it, and how its dependencies moved. */
function viewPackage (name) {
  var info = db.index[name];
  if (! info) {
    return card (name, null, el ('p', {class: 'text-muted mb-0',
                                       text: 'No such package.'}));
  }
  var series = (db.deps.packages[name] || []);
  var latest = series.length ? series[series.length - 1] : null;
  var taken = db.core.current.packages[name];
  var dependents = db.deps.dependents[name] || [];

  var facts = el ('table', {class: 'table table-sm tight mb-0'});
  function fact (term, value, mono) {
    facts.appendChild (el ('tr', {}, [
      el ('th', {class: 'text-muted fw-normal', style: 'width: 12rem',
                 text: term}),
      el ('td', {class: mono ? 'mono' : '', text: value})]));
  }
  fact ('newest release', (info.latest || '—')
        + (info.date ? '   ' + info.date : ''), true);
  fact ('status', info.status + (info.message ? ' — ' + info.message : ''));
  fact ('releases measured', info.releases.length);
  if (taken && (taken.shadows || []).length) {
    fact ('replaces in core', taken.shadows.join ('  '), true);
  }
  if (taken && (taken.extends_types || []).length) {
    fact ('extends core types', taken.extends_types.join ('  '), true);
  }

  var blocks = [card (name, null, facts)];

  if (latest && latest.declares.length) {
    blocks.push (card ('What it builds on',
      'Declared dependencies, drawn to the versions actually installed when '
      + info.latest + ' was measured.',
      drawTree (name, latest)));
  }
  if (dependents.length) {
    var who = el ('div', {class: 'namegrid'});
    dependents.forEach (function (d) { who.appendChild (pkgLink (d,
      'badge bg-light text-dark border text-decoration-none')); });
    blocks.push (card ('What builds on it',
      dependents.length + ' package' + (dependents.length === 1 ? '' : 's')
      + ' declare this one as a dependency.', who));
  }
  if (series.length > 1) {
    blocks.push (card ('How its dependencies moved',
      'One lane per dependency, one mark per release, labelled with the '
      + 'version that release was actually built against. A lane that stops '
      + 'is a dependency dropped; one that starts late was taken on.'
      + (series.length > 9 ? '  ' + series.length + ' releases — scroll '
         + 'sideways for the rest.' : ''),
      drawDependencyHistory (series)));
  }
  return el ('div', {}, blocks);
}

/* ------------------------------------------------------------------ figures */

/* A dependency tree, laid out left to right.  Each node carries two numbers
   that are easy to confuse and worth seeing together: the version that was
   actually installed when this release was measured, and the least the release
   says it will accept.  They are usually not the same, because a package that
   declared ">= 1.0.1" years ago is still built against whatever is current. */
function drawTree (root, release) {
  var nodes = [], edges = [], leaf = 0;

  function build (name, version, wants, depth, seen) {
    var entry = null;
    var series = db.deps.packages[name];
    if (series) entry = series[series.length - 1];
    var declares = (depth === 0 ? release.declares
                    : (entry ? entry.declares : []));
    var requires = (depth === 0 ? (release.requires || {})
                    : (entry ? (entry.requires || {}) : {}));
    var node = {name: name, version: version, wants: wants, depth: depth, y: 0};
    nodes.push (node);
    var kids = [];
    if (seen.indexOf (name) < 0) {
      declares.forEach (function (dep) {
        var got = (depth === 0 ? release.resolved[dep] : null);
        if (! got && db.deps.packages[dep]) {
          var s = db.deps.packages[dep];
          got = s[s.length - 1].version;
        }
        kids.push (build (dep, got, requires[dep] || '', depth + 1,
                          seen.concat ([name])));
      });
    }
    if (! kids.length) { node.y = leaf++; }
    else {
      kids.forEach (function (k) { edges.push ([node, k]); });
      node.y = kids.reduce (function (a, k) { return a + k.y; }, 0) / kids.length;
    }
    return node;
  }

  build (root, release.version, '', 0, []);

  var boxW = 172, boxH = 34, colW = 216, rowH = 46, padX = 8, padY = 12;
  var depth = Math.max.apply (null, nodes.map (function (n) { return n.depth; }));
  var width = depth * colW + boxW + padX * 2;
  var height = leaf * rowH + padY * 2;
  var fig = svg ('svg', {class: 'figure',
    viewBox: '0 0 ' + width + ' ' + Math.max (height, 60),
    role: 'img', 'aria-label': 'dependency tree for ' + root});

  function px (n) { return padX + n.depth * colW; }
  function py (n) { return padY + n.y * rowH + rowH / 2; }

  edges.forEach (function (e) {
    var x1 = px (e[0]) + boxW, x2 = px (e[1]), mid = (x1 + x2) / 2;
    fig.appendChild (svg ('path', {class: 'edge', d:
      'M' + x1 + ',' + py (e[0]) + ' C' + mid + ',' + py (e[0]) + ' '
      + mid + ',' + py (e[1]) + ' ' + x2 + ',' + py (e[1])}));
  });
  nodes.forEach (function (n) {
    var isRoot = n.depth === 0;
    fig.appendChild (svg ('rect', {class: 'node' + (isRoot ? ' root' : ''),
      x: px (n), y: py (n) - boxH / 2, width: boxW, height: boxH, rx: 4}));
    fig.appendChild (svg ('text', {
      class: 'nodelabel' + (isRoot ? ' root' : ''),
      x: px (n) + 9, y: py (n) + (n.wants ? -1 : 4),
      text: n.name + (n.version ? '  ' + n.version : '')}));
    if (n.wants) {
      fig.appendChild (svg ('text', {class: 'wants', x: px (n) + 9,
        y: py (n) + 11, text: 'needs ' + n.wants}));
    }
  });
  return fig;
}

/* One lane per dependency, one mark per release of the dependent.
   Drawn at a fixed scale and scrolled sideways rather than squeezed: a package
   with twenty eight releases would otherwise render its labels at a size
   nobody can read.  The lane names are drawn separately so that they stay put
   while the releases scroll past them. */
function drawDependencyHistory (series) {
  var lanes = [];
  series.forEach (function (r) {
    Object.keys (r.resolved).forEach (function (d) {
      if (lanes.indexOf (d) < 0) lanes.push (d);
    });
  });
  lanes.sort ();
  if (! lanes.length) {
    return el ('p', {class: 'text-muted mb-0',
                     text: 'No dependency was ever installed for this one.'});
  }

  /* padT leaves room for two lines above the first lane, not one: the
     release headings sit at the top, and the first lane's own version labels
     are drawn above its marks.  Set any tighter, the two collide. */
  var labelW = 148, padT = 62, rowH = 50, colW = 116;
  var plotW = series.length * colW;
  var height = padT + lanes.length * rowH + 26;

  var labels = svg ('svg', {width: labelW, height: height,
                            viewBox: '0 0 ' + labelW + ' ' + height,
                            class: 'plot flex-shrink-0'});
  lanes.forEach (function (dep, row) {
    labels.appendChild (svg ('text', {x: labelW - 12, y: padT + row * rowH + 11,
      'text-anchor': 'end', class: 'title', text: dep}));
  });

  var plot = svg ('svg', {width: plotW, height: height,
                          viewBox: '0 0 ' + plotW + ' ' + height, class: 'plot',
                          role: 'img', 'aria-label': 'dependency history'});
  series.forEach (function (r, ii) {
    var x = ii * colW + colW / 2;
    plot.appendChild (svg ('line', {class: 'grid', x1: x, y1: padT - 26,
      x2: x, y2: padT + lanes.length * rowH - 8}));
    plot.appendChild (svg ('text', {x: x, y: padT - 38, 'text-anchor': 'middle',
      class: 'title', text: r.version}));
    plot.appendChild (svg ('text', {x: x, y: padT + lanes.length * rowH + 8,
      'text-anchor': 'middle', text: (r.date || '').slice (0, 7)}));
  });
  lanes.forEach (function (dep, row) {
    var y = padT + row * rowH + 6;
    var last = null;
    series.forEach (function (r, ii) {
      var got = r.resolved[dep];
      if (! got) { last = null; return; }
      var x = ii * colW + colW / 2;
      if (last !== null) {
        plot.appendChild (svg ('line', {class: 'edge', x1: last, y1: y,
                                        x2: x, y2: y}));
      }
      var dot = svg ('circle', {class: 'added', cx: x, cy: y, r: 5});
      dot.appendChild (svg ('title', {text: dep + ' ' + got + ' when '
        + r.version + ' was measured'
        + ((r.requires || {})[dep] ? ', which needs ' + r.requires[dep] : '')}));
      plot.appendChild (dot);
      plot.appendChild (svg ('text', {x: x, y: y - 12, 'text-anchor': 'middle',
                                      text: got}));
      last = x;
    });
  });

  var scroller = el ('div', {class: 'overflow-auto flex-grow-1'});
  scroller.appendChild (plot);
  return el ('div', {class: 'd-flex align-items-start'}, [labels, scroller]);
}

/* ------------------------------------------------- collisions, core, chrome */

function viewCollisions () {
  var current = db.collisions.current;
  var pairs = {};
  Object.keys (current).forEach (function (name) {
    var who = {};
    current[name].forEach (function (p) { who[p.package] = true; });
    var key = Object.keys (who).sort ().join (' + ');
    (pairs[key] = pairs[key] || []).push (name);
  });

  var body = el ('div', {class: 'row g-3'});
  Object.keys (pairs).sort (function (a, b) {
    return pairs[b].length - pairs[a].length;
  }).forEach (function (key) {
    var grid = el ('div', {class: 'namegrid'});
    pairs[key].sort ().forEach (function (n) {
      grid.appendChild (el ('span', {class: 'badge bg-light text-dark border',
                                     text: n}));
    });
    var head = el ('div', {class: 'd-flex align-items-baseline gap-2 mb-2'});
    key.split (' + ').forEach (function (p) {
      head.appendChild (pkgLink (p, 'badge bg-warning text-dark text-decoration-none'));
    });
    head.appendChild (el ('span', {class: 'text-muted small',
      text: pairs[key].length + ' name' + (pairs[key].length === 1 ? '' : 's')}));
    var col = el ('div', {class: 'col-12'});
    col.appendChild (el ('div', {class: 'border rounded p-3'}, [head, grid]));
    body.appendChild (col);
  });

  return card ('Functions, scripts and classes provided twice over',
    Object.keys (current).length + ' of them answer to two packages at once. '
    + 'Load both and you get whichever came last, so these are the places two '
    + 'packages cannot be used together without surprise. Methods and '
    + 'properties are not counted here: they are reachable only through an '
    + 'object of their own class, so two classes may share a method name '
    + 'without ever contending for it.', body);
}

function viewCore () {
  var packages = db.core.current.packages;
  var body = el ('div', {class: 'row g-3'});
  Object.keys (packages).sort ().forEach (function (name) {
    var taken = packages[name];
    var grid = el ('div', {class: 'namegrid'});
    (taken.shadows || []).forEach (function (n) {
      grid.appendChild (el ('span', {class: 'badge bg-light text-dark border',
                                     text: n}));
    });
    (taken.extends_types || []).forEach (function (n) {
      grid.appendChild (el ('span', {class: 'badge bg-light text-dark border',
                                     text: '@' + n}));
    });
    var head = el ('div', {class: 'd-flex align-items-baseline gap-2 mb-2'}, [
      pkgLink (name, 'badge text-white text-decoration-none bg-purple'),
      el ('span', {class: 'text-muted small', text:
        (taken.shadows || []).length
          ? 'replaces ' + taken.shadows.length + ' core function'
            + (taken.shadows.length === 1 ? '' : 's')
          : 'adds methods to core types'})]);
    var col = el ('div', {class: 'col-12'});
    col.appendChild (el ('div', {class: 'border rounded p-3'}, [head, grid]));
    body.appendChild (col);
  });
  return card ('What packages take over from core Octave',
    'Loading a package prepends to the load path, so a name it shares with '
    + 'core replaces core’s for the rest of the session. A type extension '
    + 'shadows no name at all but changes how a core type behaves.', body);
}

/* ------------------------------------------------------------------ chrome */

function render () {
  var where = route ();
  var nav = document.getElementById ('views');
  nav.textContent = '';
  VIEWS.forEach (function (v) {
    var link = el ('a', {class: 'nav-link' + (where.view === v[0] ? ' active' : ''),
                         href: '#/' + v[0], text: v[1]});
    nav.appendChild (el ('li', {class: 'nav-item'}, [link]));
  });

  var main = document.getElementById ('main');
  main.textContent = '';
  var body;
  if (where.view === 'search') body = viewSearch (where.arg, where.query);
  else if (where.view === 'packages') body = viewPackages (where.arg);
  else if (where.view === 'collisions') body = viewCollisions ();
  else if (where.view === 'core') body = viewCore ();
  else if (where.view === 'timeline') body = viewTimeline ();
  else if (where.view === 'name') body = viewName (where.arg);
  else body = card ('Not found', null,
                    el ('p', {class: 'mb-0', text: 'No such view.'}));
  main.appendChild (body);

  var releases = 0;
  Object.keys (db.index).forEach (function (n) {
    releases += db.index[n].releases.length;
  });
  document.getElementById ('foot').innerHTML =
    Object.keys (db.index).length + ' packages · ' + releases
    + ' releases measured · ' + db.core.core_releases.length
    + ' core releases · every name read off the load path of a real '
    + 'installation, not taken from what a package declares. '
    + '<a href="https://github.com/pr0m1th3as/pkg-functions">How this works</a>.';
}

window.addEventListener ('hashchange', render);

load ().then (render).catch (function (err) {
  document.getElementById ('main').textContent = '';
  document.getElementById ('main').appendChild (card ('Could not load the data',
    null, el ('p', {class: 'mb-0', text: err.message})));
});

/* ----------------------------------------------------------------- timeline */

/* Shadowing changes drawn against time.  One lane per package, one mark per
   day something changed, sized by how many names moved at once and coloured by
   what caused it -- which is the whole point: a package can start or stop
   shadowing core without touching a line of its own code. */
function viewTimeline () {
  var groups = {};
  db.core.changes.forEach (function (c) {
    var key = c.package + '|' + c.triggered_by.date + '|' + c.event;
    if (! groups[key]) {
      groups[key] = {package: c.package, date: c.triggered_by.date,
                     event: c.event, count: 0, names: [],
                     bycore: c.triggered_by.provider === '__core__',
                     cause: c.triggered_by.provider + ' ' + c.triggered_by.version};
    }
    groups[key].count++;
    if (groups[key].names.length < 8) groups[key].names.push (c.name);
  });
  var marks = Object.keys (groups).map (function (k) { return groups[k]; });
  if (! marks.length) {
    return card ('Nothing has changed yet', null,
                 el ('p', {class: 'mb-0 text-muted', text: 'No changes on record.'}));
  }

  var lanes = [];
  marks.forEach (function (m) { if (lanes.indexOf (m.package) < 0) lanes.push (m.package); });
  lanes.sort (function (a, b) {
    var fa = Math.min.apply (null, marks.filter (function (m) { return m.package === a; })
                                        .map (function (m) { return days (m.date); }));
    var fb = Math.min.apply (null, marks.filter (function (m) { return m.package === b; })
                                        .map (function (m) { return days (m.date); }));
    return fa - fb;
  });

  var all = marks.map (function (m) { return days (m.date); })
    .concat (db.core.core_releases.map (function (v) {
      return days (coreDate (v)); }).filter (function (d) { return d > 1000; }));
  var lo = Math.min.apply (null, all), hi = Math.max.apply (null, all);

  /* A fixed number of pixels per year, and scrolled rather than squeezed.
     Eleven years already crowd the core releases against one another; drawn to
     fit a column, another five would be unreadable, and this figure is meant
     to outlast that. */
  /* padL keeps the first year label from being cut in half against the edge
     of the scroller. */
  var pxPerYear = 132, labelW = 150, padT = 78, rowH = 34, padL = 22, padR = 30;
  var y0 = parseInt (isoOf (lo).slice (0, 4), 10);
  var y1 = parseInt (isoOf (hi).slice (0, 4), 10) + 1;
  var span = days (y1 + '-01-01') - days (y0 + '-01-01');
  var plotW = padL + Math.round (span / 365.25 * pxPerYear) + padR;
  var height = padT + lanes.length * rowH + 34;
  function x (date) {
    return padL + (days (date) - days (y0 + '-01-01')) / span
                  * (plotW - padL - padR);
  }

  var labels = svg ('svg', {width: labelW, height: height, class: 'plot flex-shrink-0',
                            viewBox: '0 0 ' + labelW + ' ' + height});
  lanes.forEach (function (pkg, row) {
    labels.appendChild (svg ('text', {x: labelW - 12,
      y: padT + row * rowH + rowH / 2 + 4, 'text-anchor': 'end',
      class: 'title', text: pkg}));
  });

  var fig = svg ('svg', {class: 'plot', width: plotW, height: height,
                         viewBox: '0 0 ' + plotW + ' ' + height,
                         role: 'img', 'aria-label': 'when shadowing changed'});

  for (var yy = y0; yy <= y1; yy++) {
    var xx = x (yy + '-01-01');
    fig.appendChild (svg ('line', {class: 'grid', x1: xx, y1: padT - 12,
      x2: xx, y2: padT + lanes.length * rowH}));
    fig.appendChild (svg ('text', {x: xx, y: padT + lanes.length * rowH + 18,
      'text-anchor': 'middle', class: 'title', text: yy}));
  }

  /* Each core release named on its own rule, turned on its side because there
     is no room to write them across at this density. */
  db.core.core_releases.forEach (function (v) {
    var date = coreDate (v);
    if (! date) return;
    var xv = x (date);
    fig.appendChild (svg ('line', {class: 'corerule', x1: xv, y1: padT - 12,
      x2: xv, y2: padT + lanes.length * rowH}));
    fig.appendChild (svg ('text', {class: 'corelabel', x: xv, y: padT - 18,
      'text-anchor': 'start',
      transform: 'rotate(-90 ' + xv + ' ' + (padT - 18) + ')', text: v}));
  });

  lanes.forEach (function (pkg, row) {
    var yy2 = padT + row * rowH + rowH / 2;
    fig.appendChild (svg ('line', {class: 'grid', x1: padL, y1: yy2,
                                   x2: plotW - padR, y2: yy2, opacity: '0.4'}));
  });

  marks.forEach (function (m) {
    var yy3 = padT + lanes.indexOf (m.package) * rowH + rowH / 2;
    var r = Math.min (13, 3 + Math.sqrt (m.count) * 1.6);
    var dot = svg ('circle', {
      class: m.event === 'added' ? (m.bycore ? 'bycore' : 'added') : 'removed',
      cx: x (m.date), cy: yy3, r: r});
    dot.appendChild (svg ('title', {text:
      m.date + ' — ' + m.event + ' ' + m.count + ' name'
      + (m.count === 1 ? '' : 's') + ' (' + m.names.join (', ')
      + (m.count > m.names.length ? ', …' : '') + ') — caused by ' + m.cause}));
    fig.appendChild (dot);
  });

  var scroller = el ('div', {class: 'overflow-auto flex-grow-1'});
  scroller.appendChild (fig);
  var figure = el ('div', {class: 'd-flex align-items-start'},
                   [labels, scroller]);

  var legend = el ('p', {class: 'legend text-muted small mb-0 mt-2'});
  legend.innerHTML =
    '<span><i style="background:#fd7e14"></i>started shadowing, package changed</span>'
    + '<span><i style="background:#6f42c1"></i>started shadowing, <b>core</b> changed</span>'
    + '<span><i style="background:#fff;border:1px solid #6c757d"></i>stopped shadowing</span>'
    + '<span><i style="background:#6f42c1;opacity:.5;border-radius:0;width:2px"></i>a core release</span>'
    + ' Mark size is how many names moved at once; hover for the names.';

  return card ('When packages started and stopped shadowing core',
    'Every change replayed in date order and attributed to the release that '
    + 'caused it. The tall column in April 2018 is Octave 4.4.0 handing the '
    + 'statistics functions to the package that now carries them.',
    [figure, legend]);
}

function isoOf (dayNumber) {
  return new Date (dayNumber * 86400000).toISOString ().slice (0, 10);
}

/* A core release's date, as the merge recorded it. */
function coreDate (version) {
  return (db.core.core_dates || {})[version] || '';
}
