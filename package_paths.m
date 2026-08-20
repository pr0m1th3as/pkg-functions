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
## @deftypefn  {pkg-functions} {@var{dirlist} =} package_paths (@var{pkgname})
## @deftypefnx {pkg-functions} {[@var{dirlist}, @var{depinfo}] =} package_paths (@var{pkgname})
##
## Resolve the load path directories an installed package contributes.
##
## @code{@var{dirlist} = package_paths (@var{pkgname})} returns a cell array of
## character vectors with the directories that the installed package
## @var{pkgname} adds to the load path, and leaves the package loaded so that
## the result can be passed straight to @code{scan_functions}.
##
## The directories are measured, not guessed, by taking the difference of
## @code{path ()} across @code{pkg load}.  A single such difference is not
## enough whenever the package has dependencies, because @code{pkg load} pulls
## them in as well and credits the caller with everything they provide.  The
## whole dependency closure is therefore unloaded first and then reloaded one
## package at a time, so that each package is measured against a load path that
## already holds its dependencies and nothing of its own.  Loading
## @qcode{statistics} this way separates its 546 names from the 59 that belong
## to @qcode{datatypes}.
##
## The difference is cross-checked against the package's own installation
## directories, taken from the @qcode{dir} and @qcode{archprefix} fields of
## @code{pkg ("list", @var{pkgname})}.  Only directories below one of those
## roots are returned.  A directory added from anywhere else is reported with a
## warning rather than silently kept or silently dropped: it means the package
## put something on the load path that does not belong to it, which is a defect
## worth seeing.
##
## @code{[@var{dirlist}, @var{depinfo}] = package_paths (@var{pkgname})} also
## returns @var{depinfo}, a cell array of structures with the fields
## @qcode{name}, @qcode{version} and @qcode{dirs}, one per dependency, in the
## order they were loaded.  Dependencies on core Octave itself are not
## dependencies on a package and are skipped.
##
## Note that this function changes the interpreter's state: on return
## @var{pkgname} and its whole dependency closure are loaded, and any package
## in that closure which was loaded on entry has been unloaded and reloaded.
## That is unavoidable, since the load path cannot be measured without moving
## it, and it is the reason this belongs in a scanning run rather than in an
## interactive session.
##
## @end deftypefn

function [dirlist, depinfo] = package_paths (pkgname)

  ## Input validation
  if (nargin != 1)
    error ("package_paths: invalid number of input arguments.");
  endif
  if (! (ischar (pkgname) && isrow (pkgname)))
    error ("package_paths: PKGNAME must be a character vector.");
  endif
  if (isempty (pkg ('list', pkgname)))
    error ("package_paths: '%s' is not an installed package.", pkgname);
  endif

  ## Resolve the dependency closure, dependencies before dependents
  loadOrder = dependencyOrder (pkgname, {}, {});

  ## Unload the closure, dependents first; unloading a dependency out of order
  ## is refused, and unloading what is not loaded is a no-op.
  for ii = numel (loadOrder):-1:1
    pkg ('unload', loadOrder{ii});
  endfor

  ## Load one package at a time, measuring each against the path as it stands
  ## once its own dependencies are already in place
  dirlist = {};
  depinfo = {};
  for ii = 1:numel (loadOrder)
    thisName = loadOrder{ii};
    before = pathEntries ();
    pkg ('load', thisName);
    after = pathEntries ();
    added = after(! ismember (after, before));

    ownDirs = belowRoots (after, packageRoots (thisName));
    foreign = added(! ismember (added, ownDirs));
    if (! isempty (foreign))
      warning (strcat ("package_paths: '%s' added %d load path", ...
                       " director%s outside its own installation tree: %s"), ...
               thisName, numel (foreign), ternary (numel (foreign) == 1, ...
               'y', 'ies'), strjoin (foreign, ", "));
    endif

    if (strcmp (thisName, pkgname))
      dirlist = ownDirs;
    else
      info = pkg ('list', thisName);
      record = struct ('name', thisName, 'version', info{1}.version);
      record.dirs = ownDirs;
      depinfo{end+1} = record;
    endif
  endfor

endfunction

## Post-order walk of the dependency graph, so that every package is listed
## after the packages it depends on.  ORDER carries the packages already
## placed, STACK the ones being resolved, which is what detects a cycle.
function order = dependencyOrder (pkgname, order, stack)

  if (any (strcmp (order, pkgname)))
    return;
  endif
  if (any (strcmp (stack, pkgname)))
    error ("package_paths: circular dependency involving '%s'.", pkgname);
  endif
  stack{end+1} = pkgname;

  info = pkg ('list', pkgname);
  if (isempty (info))
    error (strcat ("package_paths: dependency '%s' is not installed."), ...
           pkgname);
  endif

  dependencies = info{1}.depends;
  for ii = 1:numel (dependencies)
    thisDep = dependencies{ii}.package;
    if (any (strcmp (thisDep, {'octave', 'pkg'})))
      continue;
    endif
    order = dependencyOrder (thisDep, order, stack);
  endfor
  order{end+1} = pkgname;

endfunction

## The load path, canonicalized so that entries compare by identity rather than
## by spelling.
function entries = pathEntries ()

  entries = strsplit (path (), pathsep ());
  for ii = 1:numel (entries)
    canonical = canonicalize_file_name (entries{ii});
    if (! isempty (canonical))
      entries{ii} = canonical;
    endif
  endfor

endfunction

## The installation directories of a package.  A package may keep its compiled
## files apart from its m-files, so both roots are needed.
function roots = packageRoots (pkgname)

  info = pkg ('list', pkgname);
  candidates = {info{1}.dir, info{1}.archprefix};
  roots = {};
  for ii = 1:numel (candidates)
    thisRoot = candidates{ii};
    ## A package shipping no compiled code can report an empty "archprefix",
    ## and an empty root would be turned into the prefix "/" below, which every
    ## absolute path starts with -- so the whole load path, core Octave and the
    ## current directory included, would be credited to the package.
    if (! (ischar (thisRoot) && ! isempty (thisRoot)))
      continue;
    endif
    canonical = canonicalize_file_name (thisRoot);
    if (! isempty (canonical))
      thisRoot = canonical;
    endif
    ## A root has to be the package's own directory and not somewhere above
    ## it.  Octave 7.1.0 reports a root that sits above core Octave and above
    ## every installed package alike, and taking it at its word credits the
    ## package with the lot: one measured release claimed 881 core functions,
    ## and 26 more belonging to its own dependency.  Both roots are laid out as
    ## "<somewhere>/<name>-<version>", so a final component that does not begin
    ## with this package's name and a hyphen belongs to something else.
    [~, base, ext] = fileparts (strip_trailing_filesep (thisRoot));
    base = [base ext];
    if (! strncmp (base, [pkgname '-'], numel (pkgname) + 1))
      warning (strcat ("package_paths: '%s' reports an installation", ...
                       " directory that is not its own, ignored: %s"), ...
               pkgname, thisRoot);
      continue;
    endif
    roots{end+1} = thisRoot;
  endfor
  if (isempty (roots))
    error (strcat ("package_paths: '%s' reports no installation", ...
                   " directory to measure against."), pkgname);
  endif
  roots = unique (roots);

endfunction

## Select the entries that lie at or below one of ROOTS.  Matching is on whole
## path components, so that "pkg-1.0.1" is not taken to be below "pkg-1.0".
function entries = belowRoots (entries, roots)

  keep = false (size (entries));
  for ii = 1:numel (roots)
    thisRoot = roots{ii};
    if (isempty (thisRoot))
      continue;   # "/" as a prefix would match every absolute path
    endif
    prefix = [thisRoot filesep()];
    keep |= strcmp (entries, thisRoot);
    keep |= strncmp (entries, prefix, numel (prefix));
  endfor
  entries = entries(keep);

endfunction

## A trailing separator would leave fileparts with an empty final component.
function out = strip_trailing_filesep (in)

  out = in;
  while (numel (out) > 1 && strcmp (out(end), filesep ()))
    out(end) = [];
  endwhile

endfunction

## Pick one of two values, to keep a message readable at its point of use.
function out = ternary (TF, yes, no)

  if (TF)
    out = yes;
  else
    out = no;
  endif

endfunction

%!error<package_paths: invalid number of input arguments.> package_paths ()
%!error<package_paths: PKGNAME must be a character vector.> package_paths (5)
%!error<package_paths: PKGNAME must be a character vector.> ...
%! package_paths ({'statistics'})
%!error<package_paths: PKGNAME must be a character vector.> ...
%! package_paths (['ab'; 'cd'])
%!error<package_paths: 'no_such_package_here' is not an installed package.> ...
%! package_paths ('no_such_package_here')

## The fixtures are installed into a prefix of their own, and the interpreter's
## real one is put back whatever happens: a test suite that leaves two packages
## behind in the user's installation has done more than test.
%!function [state, tmp] = __fixture_install__ ()
%!  root = fileparts (which ('package_paths'));
%!  [state.prefix, state.archprefix] = pkg ('prefix');
%!  state.list = pkg ('local_list');
%!  tmp = tempname ();
%!  mkdir (tmp);
%!  tar (fullfile (tmp, 'pkgfixa-1.0.0.tar.gz'), {'pkgfixa'}, ...
%!       fullfile (root, 'fixtures'));
%!  tar (fullfile (tmp, 'pkgfixb-1.0.0.tar.gz'), {'pkgfixb'}, ...
%!       fullfile (root, 'fixtures'));
%!  pkg ('prefix', fullfile (tmp, 'prefix'), fullfile (tmp, 'arch'));
%!  pkg ('local_list', fullfile (tmp, 'octave_packages'));
%!  pkg ('install', fullfile (tmp, 'pkgfixa-1.0.0.tar.gz'));
%!  pkg ('install', fullfile (tmp, 'pkgfixb-1.0.0.tar.gz'));
%!endfunction

%!function __fixture_remove__ (state, tmp)
%!  for name = {'pkgfixb', 'pkgfixa'}
%!    try
%!      pkg ('unload', name{1});
%!    catch
%!    end_try_catch
%!  endfor
%!  pkg ('prefix', state.prefix, state.archprefix);
%!  pkg ('local_list', state.list);
%!  confirm_recursive_rmdir (false, 'local');
%!  rmdir (tmp, 's');
%!endfunction

## A package is credited with its own directories and no others.
%!test
%! [state, tmp] = __fixture_install__ ();
%! unwind_protect
%!   dirlist = package_paths ('pkgfixb');
%!   assert_equal (numel (dirlist), 1);
%!   assert_equal (! isempty (strfind (dirlist{1}, 'pkgfixb-1.0.0')), true);
%! unwind_protect_cleanup
%!   __fixture_remove__ (state, tmp);
%! end_unwind_protect

## The dependency is measured apart, not folded into the dependent.
%!test
%! [state, tmp] = __fixture_install__ ();
%! unwind_protect
%!   [~, depinfo] = package_paths ('pkgfixb');
%!   assert_equal (numel (depinfo), 1);
%!   assert_equal (depinfo{1}.name, 'pkgfixa');
%!   assert_equal (depinfo{1}.version, '1.0.0');
%! unwind_protect_cleanup
%!   __fixture_remove__ (state, tmp);
%! end_unwind_protect

## The regression this file exists for: "pkg load" pulls a dependency in, and a
## bare before-and-after difference would credit its functions to the dependent.
%!test
%! [state, tmp] = __fixture_install__ ();
%! unwind_protect
%!   [dirlist, ~] = package_paths ('pkgfixb');
%!   [~, contents] = scan_functions (dirlist);
%!   names = cellfun (@(x) x.name, contents.functions, ...
%!                    'UniformOutput', false);
%!   assert_equal (sort (names), {'pkgfixb_gamma'});
%! unwind_protect_cleanup
%!   __fixture_remove__ (state, tmp);
%! end_unwind_protect

## A package with no dependencies reports none.
%!test
%! [state, tmp] = __fixture_install__ ();
%! unwind_protect
%!   [dirlist, depinfo] = package_paths ('pkgfixa');
%!   assert_equal (numel (dirlist), 1);
%!   assert_equal (isempty (depinfo), true);
%! unwind_protect_cleanup
%!   __fixture_remove__ (state, tmp);
%! end_unwind_protect
