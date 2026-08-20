## Copyright (C) 2026 Andreas Bertsatos <abertsatos@biol.uoa.gr>
##
## This file is part of the pkg-functions repository for GNU Octave.
##
## This program is free software; you can redistribute it and/or modify it under
## the terms of the GNU General Public License as published by the Free Software
## Foundation; either version 3 of the License, or (at your option) any later
## version.
##
## This program is distributed in the hope that it will be useful, but WITHOUT
## ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
## FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more
## details.
##
## You should have received a copy of the GNU General Public License along with
## this program; if not, see <http://www.gnu.org/licenses/>.

## -*- texinfo -*-
## @deftypefn  {pkg-functions} {@var{outfile} =} harvest_package (@var{pkgname}, @var{indexfile}, @var{outdir})
## @deftypefnx {pkg-functions} {@var{outfile} =} harvest_package (@dots{}, @var{name}, @var{value})
## @deftypefnx {pkg-functions} {[@var{outfile}, @var{status}] =} harvest_package (@dots{})
##
## Install a package from the Octave Packages index and record what it provides.
##
## @code{@var{outfile} = harvest_package (@var{pkgname}, @var{indexfile},
## @var{outdir})} resolves @var{pkgname} against @var{indexfile}, a local copy
## of @url{https://gnu-octave.github.io/packages/packages.json}, installs its
## newest release together with everything it depends on, scans the load path
## directories it contributes, and writes the result as
## @code{@var{outdir}/@var{pkgname}.json}.  The name of the file written is
## returned.
##
## A record is written whether or not the package could be harvested.  Its
## @qcode{status} field is @qcode{ok} when the scan succeeded, and otherwise
## names the stage that failed, with the interpreter's own message alongside in
## @qcode{message}.  A package that fails to build in the runner is thus
## reported as a package that failed to build, rather than disappearing from
## the index as though it provided nothing.  The second output @var{status} is
## zero exactly when the scan succeeded.
##
## The record also carries the @qcode{sha256} of the release it describes, taken
## from the index.  A later run whose index reports the same checksum for the
## same package describes the same files, and can be skipped without downloading
## anything.
##
## Two further fields record what the package takes over from core Octave.
## @qcode{core_shadowing} lists the names it puts on the load path that core
## already answers to, built-in functions included; because @code{pkg load}
## prepends to the load path, every one of them is a core function the package
## replaces for anyone who loads it.  @qcode{core_type_extensions} lists the
## core types it grafts methods onto through an @qcode{@@dir} carrying no
## constructor, which shadows no name but changes how a core type behaves.
## Both are measured against a load path read before anything was installed or
## loaded, so nothing the package itself contributes can be counted as core.
##
## System dependencies declared in the index for Ubuntu are installed with
## @code{apt-get} before the packages are, which needs the runner to allow
## @code{sudo} without a password.  A package already installed at the version
## the index names is left alone.
##
## Which release of each package is installed is decided by a resolution
## policy, given as @var{name}, @var{value} pairs and recorded in the
## @qcode{resolution} field of the record.
##
## @table @asis
## @item @qcode{"version"}
## Harvest the named release of @var{pkgname} rather than its newest.
##
## @item @qcode{"asof"}
## A date, @qcode{"yyyy-mm-dd"}.  Every package in the closure resolves to its
## newest release dated on or before that day, which is what makes the result
## a view of the ecosystem as it stood then.  A release carrying no date is a
## development snapshot belonging to no day, and is never selected.
## @end table
##
## Given alone, @qcode{"version"} implies an @qcode{"asof"} of the day that
## release shipped.  Without it the closure would resolve to today's releases,
## which never coexisted with the release being harvested, and the record would
## describe a combination that never existed.  Giving both is therefore a
## deliberate act: the pinned release as it would have been seen on another
## day.  Given neither, everything resolves to its newest release, and the
## record describes the ecosystem as it stands now.
##
## The record of a harvest under a policy carries what it was resolved
## against.  @qcode{resolution.backfill} is true when the release harvested is
## not the newest the index offers, which is the one thing a reader cannot
## infer from the version alone.  @qcode{dependencies} holds the closure as it
## was actually installed, so what a policy asked for and what it got are both
## on record.
##
## @seealso{package_paths, scan_functions}
## @end deftypefn

function [outfile, status] = harvest_package (pkgname, indexfile, outdir, ...
                                             varargin)

  ## Input validation
  if (nargin < 3)
    error ("harvest_package: invalid number of input arguments.");
  endif
  if (! (ischar (pkgname) && isrow (pkgname)))
    error ("harvest_package: PKGNAME must be a character vector.");
  endif
  if (! (ischar (indexfile) && isrow (indexfile)))
    error ("harvest_package: INDEXFILE must be a character vector.");
  endif
  if (exist (indexfile, 'file') != 2)
    error ("harvest_package: '%s' is not an existing file.", indexfile);
  endif
  if (! (ischar (outdir) && isrow (outdir)))
    error ("harvest_package: OUTDIR must be a character vector.");
  endif
  if (exist (outdir, 'dir') != 7)
    error ("harvest_package: '%s' is not an existing directory.", outdir);
  endif
  if (mod (numel (varargin), 2) != 0)
    error (strcat ("harvest_package: optional arguments must be given as", ...
                   " NAME, VALUE pairs."));
  endif

  requested = '';
  asof = '';
  while (numel (varargin) > 1)
    argname = varargin{1};
    argvalue = varargin{2};
    varargin(1:2) = [];
    if (! (ischar (argname) && isrow (argname)))
      error (strcat ("harvest_package: optional argument name must be a", ...
                     " character vector."));
    endif
    switch (lower (argname))
      case 'version'
        if (! (ischar (argvalue) && isrow (argvalue)))
          error ("harvest_package: VERSION must be a character vector.");
        endif
        requested = argvalue;
      case 'asof'
        if (! (ischar (argvalue) && isrow (argvalue)))
          error ("harvest_package: ASOF must be a character vector.");
        endif
        if (isempty (regexp (argvalue, '^\d{4}-\d{2}-\d{2}$', 'once')))
          error (strcat ("harvest_package: ASOF must be a date of the form", ...
                         " 'yyyy-mm-dd'."));
        endif
        asof = argvalue;
      otherwise
        error ("harvest_package: unknown optional argument '%s'.", argname);
    endswitch
  endwhile

  index = jsondecode (fileread (indexfile), 'makeValidName', false);
  if (! isfield (index, pkgname))
    error ("harvest_package: '%s' is not listed in the package index.", ...
           pkgname);
  endif

  ## A release pinned without a day to read it on is resolved as of the day it
  ## shipped, so that its dependencies are what actually coexisted with it.
  ## Resolving them to today's releases would measure a combination that never
  ## existed and file it under a version that did.
  asofImplied = false;
  if (! isempty (requested) && isempty (asof))
    pinned = findVersion (index, pkgname, requested);
    if (! isempty (entryDate (pinned)))
      asof = pinned.date;
      asofImplied = true;
    endif
  endif
  selector = struct ('asof', asof, 'pinName', pkgname, ...
                     'pinVersion', requested);

  ## Core's own names, taken before anything is installed or loaded.  Measured
  ## in this order nothing a package contributes can be counted as part of core,
  ## whatever the session already held.
  coreNames = coreFunctionNames ();
  writeCoreRecord (outdir, coreNames, asof);

  ## Seed the record from the index, so that a failure at any later stage is
  ## still reported against a release that can be identified
  entry = selectEntry (index, pkgname, selector);
  record = struct ('package', pkgname, 'version', entry.id, ...
                   'date', entry.date, 'sha256', entry.sha256, ...
                   'url', entry.url, 'octave', version (), ...
                   'status', 'ok', 'message', '');
  if (isempty (asof))
    policy = 'newest';
  else
    policy = 'asof';
  endif
  ## What the release was chosen by, kept beside what was chosen.  "backfill"
  ## is the part a reader cannot recover from the version alone: whether this
  ## record describes the package as it stands or as it once stood.
  record.resolution = struct ('policy', policy, 'asof', asof, ...
                              'asof_implied', asofImplied, ...
                              'requested', requested, ...
                              'backfill', ! strcmp (entry.id, ...
                                                    newestEntry (index, ...
                                                                 pkgname).id));
  record.dependencies = {};
  record.dropped_core_paths = {};
  outfile = fullfile (outdir, [pkgname '.json']);

  if (! isInstallable (entry))
    record.status = 'not-installable';
    record.message = 'the index declares no "pkg" dependency';
    status = writeRecord (outfile, record);
    return;
  endif

  ## Install the dependency closure, dependencies before dependents
  try
    closure = resolveClosure (index, pkgname, {}, {}, selector);
    installSystemDependencies (index, closure, selector);
    for ii = 1:numel (closure)
      installPackage (index, closure{ii}, selector);
    endfor
  catch err
    record.status = 'install-failed';
    record.message = err.message;
    status = writeRecord (outfile, record);
    return;
  end_try_catch

  ## Measure and scan
  try
    [dirlist, depinfo] = package_paths (pkgname);
    [dirlist, record.dropped_core_paths] = withoutCoreDirectories (dirlist);
    if (! isempty (record.dropped_core_paths))
      printf ("::warning::%s: %d directory(ies) inside the interpreter's own \
installation were dropped from the scan\n", ...
              pkgname, numel (record.dropped_core_paths));
    endif
    [~, contents] = scan_functions (dirlist);
    for ii = 1:numel (depinfo)
      record.dependencies{end+1} = struct ('name', depinfo{ii}.name, ...
                                           'version', depinfo{ii}.version);
    endfor
    record.contents = contents;

    ## What the package takes over from core Octave.  A name it shares with
    ## core wins, because "pkg load" prepends to the load path, so this is not
    ## a list of coincidences but of core functions the package replaces for
    ## anyone who loads it.
    record.core_shadowing = intersect (loadPathNames (contents), coreNames);
    ## An "@dir" carrying no constructor grafts methods onto a type defined
    ## elsewhere.  Where that type is core's, the package changes how a core
    ## type behaves, which shadows no name at all and so is reported apart.
    record.core_type_extensions = intersect (extensionNames (contents), ...
                                             coreNames);
    reportOverrides (pkgname, record);
  catch err
    record.status = 'scan-failed';
    record.message = err.message;
    status = writeRecord (outfile, record);
    return;
  end_try_catch

  status = writeRecord (outfile, record);

endfunction

## The directories core Octave itself puts on the load path.  Anything below a
## "site" directory was added locally and is not core -- including
## "share/octave/<version>/site/m", which sits under the same root as core's own
## m-files.  The current directory and any already loaded package need no
## excluding, since neither lies below the interpreter's installation roots.
function dirs = coreDirectories ()

  roots = coreRoots ();
  entries = strsplit (path (), pathsep ());
  keep = false (size (entries));
  for ii = 1:numel (roots)
    prefix = [roots{ii} filesep()];
    keep |= strncmp (entries, prefix, numel (prefix));
  endfor
  sitepart = [filesep() 'site' filesep()];
  keep &= cellfun (@(x) isempty (strfind (x, sitepart)), entries);
  dirs = entries(keep);

endfunction

## The interpreter's own installation roots.  Nothing below them belongs to a
## package: a package installs under "share/octave/packages".
function roots = coreRoots ()

  roots = {fullfile(OCTAVE_HOME (), 'share', 'octave', version ()), ...
           fullfile(OCTAVE_HOME (), 'lib', 'octave', version ())};

endfunction

## Drop the directories that lie inside the interpreter's own installation.
##
## A package cannot own one, so a load path difference that reports it has
## measured something other than the package.  Octave 7.1.0 was seen to drop
## core's directories and restore them across an unload and reload, which made
## the difference credit 881 core functions to whichever package was loading;
## the record then showed the package shadowing half of core.  Anything below a
## "site" directory is excluded from the test, exactly as it is when core's own
## names are gathered: it was added locally and is not part of the interpreter.
function [dirs, dropped] = withoutCoreDirectories (dirs)

  roots = coreRoots ();
  isCore = false (size (dirs));
  for ii = 1:numel (roots)
    prefix = [roots{ii} filesep()];
    isCore |= strncmp (dirs, prefix, numel (prefix));
  endfor
  sitepart = [filesep() 'site' filesep()];
  isCore &= cellfun (@(x) isempty (strfind (x, sitepart)), dirs);
  dropped = dirs(isCore);
  dirs = dirs(! isCore);

endfunction

## Every name core Octave answers to: what its own load path directories
## provide, plus the built-in functions, which live in the interpreter and sit
## on no path at all.  Leaving the built-ins out would hide a package shadowing
## "size" or "zeros", which is the worst case there is.
function names = coreFunctionNames ()

  [~, contents] = scan_functions (coreDirectories ());
  names = union (loadPathNames (contents), __builtins__ ());

endfunction

## Record core Octave's own names as one more provider in the data set.
##
## Core is not fixed.  Functions enter and leave it between releases, so a
## package can begin shadowing one without changing at all -- core need only
## gain the name.  Stored this way, that shows up as a change to core rather
## than being silently attributed to the package, and any release already held
## can have its shadowing recomputed against a core it was never measured
## against, without installing anything again.
##
## The date is the day the measurement was made, not a release date, which is
## not something the interpreter can tell us.  It reads as "from when we began
## measuring against this core", which is what it is.
##
## Under a policy it is the day being reconstructed instead, because that is
## the day this core is being offered as the core of.  The distinction is not
## cosmetic: the merge replays providers in date order, so a core measured for
## a past day has to carry that day or it arrives after every core already
## held and is taken for a newer one.
function writeCoreRecord (outdir, coreNames, asof)

  if (isempty (asof))
    recorded = datestr (now (), 'yyyy-mm-dd');
  else
    recorded = asof;
  endif
  record = struct ('package', '__core__', 'version', version (), ...
                   'date', recorded, ...
                   'octave', version (), 'status', 'ok', 'message', '');
  record.names = coreNames(:)';

  outfile = fullfile (outdir, '__core__.json');
  fid = fopen (outfile, 'w');
  if (fid < 0)
    error ("harvest_package: cannot write '%s'.", outfile);
  endif
  fputs (fid, jsonencode (record));
  fclose (fid);

endfunction

## The names a scan puts on the load path.  Methods and properties are left
## out: they are reachable only through an object of their own class, so they
## cannot shadow a function of the same name.
function names = loadPathNames (contents)

  names = {};
  for field = {'functions', 'namespaced_functions', 'scripts', 'classes', ...
               'namespaced_classes', 'oldstyle_classes'}
    records = contents.(field{1});
    for ii = 1:numel (records)
      names{end+1} = records{ii}.name;
    endfor
  endfor
  names = unique (names);

endfunction

## The types that an "@dir" holding no constructor adds methods to.
function names = extensionNames (contents)

  names = {};
  for ii = 1:numel (contents.method_extensions)
    names{end+1} = contents.method_extensions{ii}.name;
  endfor
  names = unique (names);

endfunction

## Annotate what the package takes over from core, so that it shows in the
## run log and not only in the data.
function reportOverrides (pkgname, record)

  if (! isempty (record.core_shadowing))
    printf ("::warning::%s shadows %d core function(s): %s\n", pkgname, ...
            numel (record.core_shadowing), ...
            strjoin (record.core_shadowing, " "));
  endif
  if (! isempty (record.core_type_extensions))
    printf ("::warning::%s adds methods to %d core type(s): %s\n", pkgname, ...
            numel (record.core_type_extensions), ...
            strjoin (record.core_type_extensions, " "));
  endif

endfunction

## Every release the index lists for a package, newest first.  The list is
## stored as a structure array, or as a cell array when its entries do not
## share the same fields; a cell array of entries is the one shape the rest of
## this file has to deal with.
function versions = indexVersions (index, pkgname)

  entries = index.(pkgname).versions;
  if (iscell (entries))
    versions = reshape (entries, 1, []);
  else
    versions = arrayfun (@(x) x, reshape (entries, 1, []), ...
                         'UniformOutput', false);
  endif

endfunction

## The newest release of a package, whatever policy is in force.  Only the
## record's "backfill" flag needs this: everything else asks for the release
## the policy selects.
function entry = newestEntry (index, pkgname)

  versions = indexVersions (index, pkgname);
  entry = versions{1};

endfunction

## A named release of a package, or an error naming the releases there are.
function entry = findVersion (index, pkgname, wanted)

  versions = indexVersions (index, pkgname);
  for ii = 1:numel (versions)
    if (strcmp (versions{ii}.id, wanted))
      entry = versions{ii};
      return;
    endif
  endfor
  ids = cellfun (@(x) x.id, versions, 'UniformOutput', false);
  error ("harvest_package: '%s' has no release '%s'; it has %s.", ...
         pkgname, wanted, strjoin (ids, ", "));

endfunction

## The date a release carries, or empty when it carries none.  The development
## snapshots the index lists have no date at all, and so belong to no day.
function thisdate = entryDate (entry)

  thisdate = '';
  if (isfield (entry, 'date') && ischar (entry.date) ...
      && ! isempty (regexp (entry.date, '^\d{4}-\d{2}-\d{2}$', 'once')))
    thisdate = entry.date;
  endif

endfunction

## The release the resolution policy selects for a package: the pinned one for
## the package that was pinned, otherwise the newest dated on or before the day
## being reconstructed, otherwise simply the newest.
##
## A dated release is compared as a number rather than as text, so that the
## comparison does not depend on how two char vectors happen to order.
function entry = selectEntry (index, pkgname, selector)

  if (strcmp (pkgname, selector.pinName) && ! isempty (selector.pinVersion))
    entry = findVersion (index, pkgname, selector.pinVersion);
    return;
  endif

  versions = indexVersions (index, pkgname);
  if (isempty (selector.asof))
    entry = versions{1};
    return;
  endif

  ## Newest first, so the first release old enough is the one wanted.
  limit = dateNumber (selector.asof);
  for ii = 1:numel (versions)
    thisdate = entryDate (versions{ii});
    if (! isempty (thisdate) && dateNumber (thisdate) <= limit)
      entry = versions{ii};
      return;
    endif
  endfor
  error ("harvest_package: '%s' had no release on or before %s.", ...
         pkgname, selector.asof);

endfunction

## A "yyyy-mm-dd" date as the number yyyymmdd, which orders the same way.
function num = dateNumber (thisdate)

  num = str2double (strrep (thisdate, '-', ''));

endfunction

## Only a package declaring a "pkg" dependency can be installed by "pkg".
function TF = isInstallable (entry)

  TF = isfield (entry, 'depends') ...
       && any (strcmp (dependencyNames (entry), 'pkg'));

endfunction

## The bare package names a release depends on, stripped of version constraints.
function names = dependencyNames (entry)

  names = {};
  if (! isfield (entry, 'depends'))
    return;
  endif
  depends = entry.depends;
  for ii = 1:numel (depends)
    if (iscell (depends))
      thisDep = depends{ii};
    else
      thisDep = depends(ii);
    endif
    if (isstruct (thisDep))
      names{end+1} = thisDep.name;
    else
      names{end+1} = strtok (thisDep);
    endif
  endfor

endfunction

## Post-order walk of the index dependency graph, dependencies before
## dependents.  Core Octave and the "pkg" marker are not packages to install.
function order = resolveClosure (index, pkgname, order, stack, selector)

  if (any (strcmp (order, pkgname)))
    return;
  endif
  if (any (strcmp (stack, pkgname)))
    error ("harvest_package: circular dependency involving '%s'.", pkgname);
  endif
  if (! isfield (index, pkgname))
    error ("harvest_package: dependency '%s' is not in the package index.", ...
           pkgname);
  endif
  stack{end+1} = pkgname;

  ## The dependencies of the release the policy selects, which are not the
  ## dependencies its newest release declares.
  names = dependencyNames (selectEntry (index, pkgname, selector));
  for ii = 1:numel (names)
    if (any (strcmp (names{ii}, {'octave', 'pkg'})))
      continue;
    endif
    order = resolveClosure (index, names{ii}, order, stack, selector);
  endfor
  order{end+1} = pkgname;

endfunction

## Install the Ubuntu packages the closure declares, in one apt-get call.
function installSystemDependencies (index, closure, selector)

  aptNames = {};
  for ii = 1:numel (closure)
    entry = selectEntry (index, closure{ii}, selector);
    if (! isfield (entry, 'ubuntu2604') || isempty (entry.ubuntu2604))
      continue;
    endif
    aptNames = [aptNames, reshape(cellstr (entry.ubuntu2604), 1, [])];
  endfor
  aptNames = unique (aptNames);
  if (isempty (aptNames))
    return;
  endif

  ## An Ubuntu package name holds only lower case letters, digits, plus and
  ## minus signs and periods; anything else is not going into a shell command.
  for ii = 1:numel (aptNames)
    if (isempty (regexp (aptNames{ii}, '^[a-z0-9\+\-\.]+$', 'once')))
      error ("harvest_package: invalid Ubuntu package name '%s'.", ...
             aptNames{ii});
    endif
  endfor

  system ("sudo apt-get update");
  cmd = strcat ("sudo DEBIAN_FRONTEND=noninteractive TZ=Etc/UTC", ...
                " apt-get install --yes ", strjoin (aptNames, " "));
  if (system (cmd) != 0)
    error ("harvest_package: apt-get failed for: %s.", strjoin (aptNames, " "));
  endif

endfunction

## Install one package from the index, unless the version it names is already
## installed.
function installPackage (index, pkgname, selector)

  entry = selectEntry (index, pkgname, selector);
  installed = pkg ('list', pkgname);
  if (! isempty (installed) && strcmp (installed{1}.version, entry.id))
    return;
  endif
  pkg ('install', entry.url);

endfunction

## Write the record and report whether it describes a successful scan.
function status = writeRecord (outfile, record)

  fid = fopen (outfile, 'w');
  if (fid < 0)
    error ("harvest_package: cannot write '%s'.", outfile);
  endif
  fputs (fid, jsonencode (record));
  fclose (fid);
  status = ! strcmp (record.status, 'ok');
  if (status)
    printf ("::error::%s: %s: %s\n", record.package, record.status, ...
            record.message);
  endif

endfunction

%!error<harvest_package: invalid number of input arguments.> harvest_package ()
%!error<harvest_package: invalid number of input arguments.> ...
%! harvest_package ('a')
%!error<harvest_package: PKGNAME must be a character vector.> ...
%! harvest_package (5, 'f', 'd')
%!error<harvest_package: INDEXFILE must be a character vector.> ...
%! harvest_package ('a', 5, 'd')
%!error<harvest_package: 'no_such_index_file' is not an existing file.> ...
%! harvest_package ('a', 'no_such_index_file', 'd')
%!error<harvest_package: optional arguments must be given as NAME, VALUE pairs.> ...
%! harvest_package ('a', which ('harvest_package'), tempdir (), 'asof')
%!error<harvest_package: optional argument name must be a character vector.> ...
%! harvest_package ('a', which ('harvest_package'), tempdir (), 5, '1.0')
%!error<harvest_package: VERSION must be a character vector.> ...
%! harvest_package ('a', which ('harvest_package'), tempdir (), 'version', 5)
%!error<harvest_package: ASOF must be a character vector.> ...
%! harvest_package ('a', which ('harvest_package'), tempdir (), 'asof', 5)
%!error<harvest_package: ASOF must be a date of the form 'yyyy-mm-dd'.> ...
%! harvest_package ('a', which ('harvest_package'), tempdir (), 'asof', '1-1-26')
%!error<harvest_package: unknown optional argument 'whenever'.> ...
%! harvest_package ('a', which ('harvest_package'), tempdir (), 'whenever', 'x')

%!function __write__ (fname, txt)
%!  fid = fopen (fname, 'w');
%!  fputs (fid, txt);
%!  fclose (fid);
%!endfunction

%!function __remove__ (tmpDir)
%!  confirm_recursive_rmdir (false, 'local');
%!  rmdir (tmpDir, 's');
%!endfunction

%!function __index__ (fname)
%!  __write__ (fname, ['{"demo":{"versions":[' ...
%!    '{"id":"2.0","date":"2026-06-01","sha256":"b","url":"u2",' ...
%!    '"depends":["octave (>= 6.1.0)"]},' ...
%!    '{"id":"1.0","date":"2024-03-01","sha256":"a","url":"u1",' ...
%!    '"depends":["octave (>= 6.1.0)"]}]}}']);
%!endfunction

## Declaring no "pkg" dependency, the fixture is recorded without being
## installed, which leaves the release the policy chose observable on its own.
%!test
%! tmpDir = tempname ();
%! mkdir (tmpDir);
%! unwind_protect
%!   idxFile = fullfile (tmpDir, 'index.json');
%!   __index__ (idxFile);
%!   harvest_package ('demo', idxFile, tmpDir);
%!   record = jsondecode (fileread (fullfile (tmpDir, 'demo.json')));
%!   assert_equal (record.version, '2.0');
%!   assert_equal (record.resolution.policy, 'newest');
%!   assert_equal (record.resolution.backfill, false);
%!   assert_equal (isempty (record.dropped_core_paths), true);
%! unwind_protect_cleanup
%!   confirm_recursive_rmdir (false, 'local');
%!   rmdir (tmpDir, 's');
%! end_unwind_protect

%!test
%! tmpDir = tempname ();
%! mkdir (tmpDir);
%! unwind_protect
%!   idxFile = fullfile (tmpDir, 'index.json');
%!   __index__ (idxFile);
%!   harvest_package ('demo', idxFile, tmpDir, 'asof', '2025-01-01');
%!   record = jsondecode (fileread (fullfile (tmpDir, 'demo.json')));
%!   assert_equal (record.version, '1.0');
%!   assert_equal (record.resolution.policy, 'asof');
%!   assert_equal (record.resolution.asof, '2025-01-01');
%!   assert_equal (record.resolution.backfill, true);
%! unwind_protect_cleanup
%!   confirm_recursive_rmdir (false, 'local');
%!   rmdir (tmpDir, 's');
%! end_unwind_protect

## A pinned release is read as of the day it shipped, so the core it is
## measured against is dated that day and not the day of the harvest.
%!test
%! tmpDir = tempname ();
%! mkdir (tmpDir);
%! unwind_protect
%!   idxFile = fullfile (tmpDir, 'index.json');
%!   __index__ (idxFile);
%!   harvest_package ('demo', idxFile, tmpDir, 'version', '1.0');
%!   record = jsondecode (fileread (fullfile (tmpDir, 'demo.json')));
%!   assert_equal (record.version, '1.0');
%!   assert_equal (record.resolution.asof, '2024-03-01');
%!   assert_equal (record.resolution.asof_implied, true);
%!   core = jsondecode (fileread (fullfile (tmpDir, '__core__.json')));
%!   assert_equal (core.date, '2024-03-01');
%! unwind_protect_cleanup
%!   confirm_recursive_rmdir (false, 'local');
%!   rmdir (tmpDir, 's');
%! end_unwind_protect

%!error<harvest_package: 'demo' has no release '3.0'; it has 2.0, 1.0.> ...
%! tmpDir = tempname ();
%! mkdir (tmpDir);
%! cleanupObj = onCleanup (@() __remove__ (tmpDir));
%! idxFile = fullfile (tmpDir, 'index.json');
%! __index__ (idxFile);
%! harvest_package ('demo', idxFile, tmpDir, 'version', '3.0');

%!error<harvest_package: 'demo' had no release on or before 2020-01-01.> ...
%! tmpDir = tempname ();
%! mkdir (tmpDir);
%! cleanupObj = onCleanup (@() __remove__ (tmpDir));
%! idxFile = fullfile (tmpDir, 'index.json');
%! __index__ (idxFile);
%! harvest_package ('demo', idxFile, tmpDir, 'asof', '2020-01-01');
