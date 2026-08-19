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
## @seealso{package_paths, scan_functions}
## @end deftypefn

function [outfile, status] = harvest_package (pkgname, indexfile, outdir)

  ## Input validation
  if (nargin != 3)
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

  index = jsondecode (fileread (indexfile), 'makeValidName', false);
  if (! isfield (index, pkgname))
    error ("harvest_package: '%s' is not listed in the package index.", ...
           pkgname);
  endif

  ## Core's own names, taken before anything is installed or loaded.  Measured
  ## in this order nothing a package contributes can be counted as part of core,
  ## whatever the session already held.
  coreNames = coreFunctionNames ();

  ## Seed the record from the index, so that a failure at any later stage is
  ## still reported against a release that can be identified
  entry = indexEntry (index, pkgname);
  record = struct ('package', pkgname, 'version', entry.id, ...
                   'date', entry.date, 'sha256', entry.sha256, ...
                   'url', entry.url, 'octave', version (), ...
                   'status', 'ok', 'message', '');
  record.dependencies = {};
  outfile = fullfile (outdir, [pkgname '.json']);

  if (! isInstallable (entry))
    record.status = 'not-installable';
    record.message = 'the index declares no "pkg" dependency';
    status = writeRecord (outfile, record);
    return;
  endif

  ## Install the dependency closure, dependencies before dependents
  try
    closure = resolveClosure (index, pkgname, {}, {});
    installSystemDependencies (index, closure);
    for ii = 1:numel (closure)
      installPackage (index, closure{ii});
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

  roots = {fullfile(OCTAVE_HOME (), 'share', 'octave', version ()), ...
           fullfile(OCTAVE_HOME (), 'lib', 'octave', version ())};
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

## Every name core Octave answers to: what its own load path directories
## provide, plus the built-in functions, which live in the interpreter and sit
## on no path at all.  Leaving the built-ins out would hide a package shadowing
## "size" or "zeros", which is the worst case there is.
function names = coreFunctionNames ()

  [~, contents] = scan_functions (coreDirectories ());
  names = union (loadPathNames (contents), __builtins__ ());

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

## The newest release of a package.  The index stores the version list as a
## structure array, or as a cell array when its entries do not share the same
## fields, and the newest is first either way.
function entry = indexEntry (index, pkgname)

  versions = index.(pkgname).versions;
  if (iscell (versions))
    entry = versions{1};
  else
    entry = versions(1);
  endif

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
function order = resolveClosure (index, pkgname, order, stack)

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

  names = dependencyNames (indexEntry (index, pkgname));
  for ii = 1:numel (names)
    if (any (strcmp (names{ii}, {'octave', 'pkg'})))
      continue;
    endif
    order = resolveClosure (index, names{ii}, order, stack);
  endfor
  order{end+1} = pkgname;

endfunction

## Install the Ubuntu packages the closure declares, in one apt-get call.
function installSystemDependencies (index, closure)

  aptNames = {};
  for ii = 1:numel (closure)
    entry = indexEntry (index, closure{ii});
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
function installPackage (index, pkgname)

  entry = indexEntry (index, pkgname);
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
