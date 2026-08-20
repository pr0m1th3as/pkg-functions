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
## @deftypefn  {pkg-functions} {@var{json} =} scan_functions (@var{dirlist})
## @deftypefnx {pkg-functions} {[@var{json}, @var{S}] =} scan_functions (@var{dirlist})
##
## Enumerate everything a set of load path directories provides.
##
## @code{@var{json} = scan_functions (@var{dirlist})} scans the directories
## listed in @var{dirlist}, a cell array of character vectors, and returns a
## character vector with a JSON representation of every callable name they add
## to the load path.  @var{dirlist} typically holds the directories a package
## contributes, which can be captured as the difference of @code{path ()} taken
## before and after @code{pkg load}.
##
## Every directory in @var{dirlist} must exist and must already be on the load
## path.  The requirement is not cosmetic: classes are identified by asking the
## interpreter through @code{meta.class.fromName}, which only resolves names
## that are reachable, and an unreachable class would be silently misreported
## as an ordinary function.
##
## Directories are scanned recursively through namespace (@qcode{+}) and class
## (@qcode{@@}) subdirectories.  Anything else, @code{private} included, is not
## descended into, since it contributes no callable name of its own.
##
## The returned JSON is an object with the following fields.
##
## @multitable @columnfractions 0.28 0.72
## @headitem Field @tab Content
## @item @qcode{paths} @tab The scanned directories, as given.
## @item @qcode{functions} @tab Plain functions, each with the @qcode{file}
## that defines it and a @qcode{type} of @qcode{m}, @qcode{oct} or @qcode{mex}.
## @item @qcode{namespaced_functions} @tab As above, named @qcode{ns.fcn}.
## @item @qcode{scripts} @tab Script files.  A script occupies a name on the
## load path but takes no arguments, and any function defined inside it is
## local to it and is not reported.
## @item @qcode{classes} @tab @code{classdef} classes, each with its public
## @qcode{methods}, @qcode{properties} and @qcode{superclasses}.
## @item @qcode{namespaced_classes} @tab As above, named @qcode{ns.Class}.
## @item @qcode{oldstyle_classes} @tab @qcode{@@dir} classes, identified by the
## presence of a constructor file, each with its @qcode{methods}.
## @item @qcode{method_extensions} @tab @qcode{@@dir} directories with no
## constructor, which do not define a class but add or override methods on a
## type defined elsewhere.
## @end multitable
##
## Only public, non-hidden methods and properties are reported.  Hidden members
## are deliberately excluded: they are the mechanism by which a class keeps an
## unimplemented or internal method out of its user facing documentation, and
## listing them here would undo that.
##
## @code{[@var{json}, @var{S}] = scan_functions (@var{dirlist})} also returns
## @var{S}, the scalar structure the JSON was encoded from.
##
## @end deftypefn

function [json, S] = scan_functions (dirlist)

  ## Input validation
  if (nargin != 1)
    error ("scan_functions: invalid number of input arguments.");
  endif
  if (! iscellstr (dirlist))
    error (strcat ("scan_functions: DIRLIST must be a cell array of", ...
                   " character vectors."));
  endif
  if (isempty (dirlist))
    error ("scan_functions: DIRLIST must not be empty.");
  endif

  loadPath = strsplit (path (), pathsep ());
  for ii = 1:numel (loadPath)
    canonical = canonicalize_file_name (loadPath{ii});
    if (! isempty (canonical))
      loadPath{ii} = canonical;
    endif
  endfor

  scanDirs = cell (1, numel (dirlist));
  for ii = 1:numel (dirlist)
    if (exist (dirlist{ii}, 'dir') != 7)
      error ("scan_functions: '%s' is not an existing directory.", dirlist{ii});
    endif
    scanDirs{ii} = canonicalize_file_name (dirlist{ii});
    if (! any (strcmp (loadPath, scanDirs{ii})))
      error (strcat ("scan_functions: '%s' is not on the load path.", ...
                     " Class detection requires every scanned directory", ...
                     " to be reachable."), dirlist{ii});
    endif
  endfor

  ## Collect candidate names and class directories
  candidates = cell (0, 2);
  classDirs = cell (0, 2);
  for ii = 1:numel (scanDirs)
    [names, dirs] = scanDirectory (scanDirs{ii}, '');
    candidates = [candidates; names];
    classDirs = [classDirs; dirs];
  endfor

  ## Sort each candidate into a class, a script or a plain function.  Classes
  ## are recognized by asking the interpreter rather than by reading the file,
  ## which is the only way that resolves a namespaced class correctly.
  functions = {};
  nsFunctions = {};
  scripts = {};
  classes = {};
  nsClasses = {};
  for ii = 1:rows (candidates)
    thisName = candidates{ii,1};
    thisFile = candidates{ii,2};
    isNamespaced = any (thisName == '.');
    metaClass = meta.class.fromName (thisName);
    if (! isempty (metaClass))
      record = classRecord (thisName, thisFile, metaClass);
      if (isNamespaced)
        nsClasses{end+1} = record;
      else
        classes{end+1} = record;
      endif
    elseif (isScript (thisName, thisFile))
      scripts{end+1} = struct ('name', thisName, 'file', thisFile, ...
                               'type', 'script');
    else
      record = functionRecord (thisName, thisFile);
      if (isNamespaced)
        nsFunctions{end+1} = record;
      else
        functions{end+1} = record;
      endif
    endif
  endfor

  ## An "@dir" holds a class only if it also holds its constructor; without one
  ## it adds or overrides methods on a type that is defined elsewhere.
  oldClasses = {};
  extensions = {};
  for ii = 1:rows (classDirs)
    thisDir = classDirs{ii,1};
    prefix = classDirs{ii,2};
    [~, dirName] = fileparts (thisDir);
    shortName = dirName(2:end);
    methodNames = directoryMethods (thisDir);
    record = struct ('name', [prefix shortName], 'dir', thisDir);
    if (any (strcmp (methodNames, shortName)))
      record.methods = setdiff (methodNames, {shortName});
      oldClasses{end+1} = record;
    else
      record.methods = methodNames;
      extensions{end+1} = record;
    endif
  endfor

  ## Assemble, sorted by name so that two scans of the same tree compare
  S.paths = dirlist(:)';
  S.functions = sortRecords (functions);
  S.namespaced_functions = sortRecords (nsFunctions);
  S.scripts = sortRecords (scripts);
  S.classes = sortRecords (classes);
  S.namespaced_classes = sortRecords (nsClasses);
  S.oldstyle_classes = sortRecords (oldClasses);
  S.method_extensions = sortRecords (extensions);

  ## Encoded only when the caller asked for it.  harvest_package wants the
  ## structure and discards this, and encoding it anyway is the one place the
  ## scan would need JSON support that Octave gained only at 7.1 -- which is
  ## the whole interpreter range the historical sweep reaches back through.
  if (isargout (1))
    json = encodeJSON (S);
  else
    json = '';
  endif

endfunction

## Recursively list the callable names a directory contributes, descending into
## namespace subdirectories only.  Class directories are returned unvisited,
## along with the namespace prefix in effect where they were found.
function [names, classDirs] = scanDirectory (dirName, prefix)

  names = cell (0, 2);
  classDirs = cell (0, 2);

  for ext = {'*.m', '*.oct', '*.mex'}
    files = glob (fullfile (dirName, ext{1}));
    for ii = 1:numel (files)
      [~, base] = fileparts (files{ii});
      names(end+1,:) = {[prefix base], files{ii}};
    endfor
  endfor

  entries = dir (dirName);
  for ii = 1:numel (entries)
    if (! entries(ii).isdir || numel (entries(ii).name) < 2)
      continue;
    endif
    base = entries(ii).name;
    if (base(1) == '+')
      [subNames, subDirs] = scanDirectory (fullfile (dirName, base), ...
                                           [prefix base(2:end) '.']);
      names = [names; subNames];
      classDirs = [classDirs; subDirs];
    elseif (base(1) == '@')
      classDirs(end+1,:) = {fullfile(dirName, base), prefix};
    endif
  endfor

endfunction

## Describe a plain function.
function record = functionRecord (name, file)

  [~, ~, ext] = fileparts (file);
  switch (ext)
    case '.oct'
      fileType = 'oct';
    case '.mex'
      fileType = 'mex';
    otherwise
      fileType = 'm';
  endswitch
  record = struct ('name', name, 'file', file, 'type', fileType);

endfunction

## A script file occupies a name but defines no callable interface.  Ask the
## interpreter, which is authoritative, but only when it answers for this very
## file; the load path may resolve the name to a different one, in which case
## fall back to reading the file the way Octave itself decides.
function TF = isScript (name, file)

  [~, ~, ext] = fileparts (file);
  if (! strcmp (ext, '.m'))
    TF = false;
    return;
  endif
  info = __which__ (name);
  if (strcmp (info.file, file))
    TF = strcmp (info.type, 'script');
  else
    TF = ! opensWithFunction (file);
  endif

endfunction

## True when the first token of a file that is neither blank nor comment is the
## "function" keyword, which is what makes a file a function file.
function TF = opensWithFunction (file)

  TF = false;
  fid = fopen (file, 'r');
  if (fid < 0)
    return;
  endif
  inBlockComment = false;
  while (ischar (txt = fgetl (fid)))
    txt = strtrim (txt);
    if (isempty (txt))
      continue;
    endif
    if (inBlockComment)
      if (any (strcmp (txt, {'%}', '#}'})))
        inBlockComment = false;
      endif
      continue;
    endif
    if (any (strcmp (txt, {'%{', '#{'})))
      inBlockComment = true;
      continue;
    endif
    if (any (txt(1) == '%#'))
      continue;
    endif
    TF = ! isempty (regexp (txt, '^function\>', 'once'));
    break;
  endwhile
  fclose (fid);

endfunction

## Describe a classdef class, keeping only its public, non-hidden members.
function record = classRecord (name, file, metaClass)

  methodNames = {};
  for ii = 1:numel (metaClass.MethodList)
    thisMethod = metaClass.MethodList{ii};
    if (thisMethod.Hidden || ! isPublic (thisMethod.Access))
      continue;
    endif
    methodNames{end+1} = thisMethod.Name;
  endfor

  propertyNames = {};
  for ii = 1:numel (metaClass.PropertyList)
    thisProperty = metaClass.PropertyList{ii};
    if (thisProperty.Hidden || ! isPublic (thisProperty.GetAccess))
      continue;
    endif
    propertyNames{end+1} = thisProperty.Name;
  endfor

  superNames = {};
  for ii = 1:numel (metaClass.SuperclassList)
    superNames{end+1} = metaClass.SuperclassList{ii}.Name;
  endfor

  record = struct ('name', name, 'file', file);
  record.methods = unique (methodNames);
  record.properties = unique (propertyNames);
  record.superclasses = unique (superNames);

endfunction

## An access specifier is either a character vector or, when a class restricts
## access to a list of classes, a cell array; only the former can be public.
function TF = isPublic (access)

  TF = ischar (access) && strcmp (access, 'public');

endfunction

## List the method files held directly in an "@dir".
function methodNames = directoryMethods (dirName)

  methodNames = {};
  for ext = {'*.m', '*.oct', '*.mex'}
    files = glob (fullfile (dirName, ext{1}));
    for ii = 1:numel (files)
      [~, base] = fileparts (files{ii});
      methodNames{end+1} = base;
    endfor
  endfor
  methodNames = unique (methodNames);

endfunction

## Order a list of records by name, so that rescanning an unchanged tree
## reproduces the previous output byte for byte.
function records = sortRecords (records)

  if (isempty (records))
    return;
  endif
  names = cellfun (@(x) x.name, records, 'UniformOutput', false);
  [~, idx] = sort (names);
  records = records(idx);

endfunction

%!function __write__ (fname, txt)
%!  fid = fopen (fname, 'w');
%!  fputs (fid, txt);
%!  fclose (fid);
%!endfunction

%!test
%! tmpDir = tempname ();
%! mkdir (tmpDir);
%! unwind_protect
%!   mkdir (fullfile (tmpDir, '+ns'));
%!   mkdir (fullfile (tmpDir, '@oldcls'));
%!   mkdir (fullfile (tmpDir, '@ext'));
%!   mkdir (fullfile (tmpDir, 'private'));
%!   __write__ (fullfile (tmpDir, 'plainfcn.m'), ...
%!              "function plainfcn ()\nendfunction\n");
%!   __write__ (fullfile (tmpDir, 'someclass.m'), ...
%!              "classdef someclass\nendclassdef\n");
%!   __write__ (fullfile (tmpDir, 'plainscript.m'), "x = 42;\n");
%!   __write__ (fullfile (tmpDir, 'cmdfile.m'), ...
%!              "1;\nfunction local ()\nendfunction\n");
%!   __write__ (fullfile (tmpDir, '+ns', 'nsfcn.m'), ...
%!              "function nsfcn ()\nendfunction\n");
%!   __write__ (fullfile (tmpDir, '@oldcls', 'oldcls.m'), ...
%!              "function s = oldcls ()\n  s = class (struct (), 'oldcls');\nendfunction\n");
%!   __write__ (fullfile (tmpDir, '@oldcls', 'size.m'), ...
%!              "function size (this)\nendfunction\n");
%!   __write__ (fullfile (tmpDir, '@ext', 'disp.m'), ...
%!              "function disp (this)\nendfunction\n");
%!   __write__ (fullfile (tmpDir, 'private', 'helper.m'), ...
%!              "function helper ()\nendfunction\n");
%!   addpath (tmpDir);
%!   rehash ();
%!   [json, S] = scan_functions ({tmpDir});
%!   assert_equal (class (json), 'char');
%!   assert_equal (numel (S.functions), 1);
%!   assert_equal (S.functions{1}.name, 'plainfcn');
%!   assert_equal (S.functions{1}.type, 'm');
%!   assert_equal (numel (S.namespaced_functions), 1);
%!   assert_equal (S.namespaced_functions{1}.name, 'ns.nsfcn');
%!   assert_equal (numel (S.scripts), 2);
%!   assert_equal (S.scripts{1}.name, 'cmdfile');
%!   assert_equal (S.scripts{2}.name, 'plainscript');
%!   assert_equal (numel (S.classes), 1);
%!   assert_equal (S.classes{1}.name, 'someclass');
%!   assert_equal (numel (S.oldstyle_classes), 1);
%!   assert_equal (S.oldstyle_classes{1}.name, 'oldcls');
%!   assert_equal (S.oldstyle_classes{1}.methods, {'size'});
%!   assert_equal (numel (S.method_extensions), 1);
%!   assert_equal (S.method_extensions{1}.name, 'ext');
%!   assert_equal (S.method_extensions{1}.methods, {'disp'});
%! unwind_protect_cleanup
%!   rmpath (tmpDir);
%!   confirm_recursive_rmdir (false, 'local');
%!   rmdir (tmpDir, 's');
%! end_unwind_protect

%!error<scan_functions: invalid number of input arguments.> scan_functions ()
%!error<scan_functions: DIRLIST must be a cell array of character vectors.> ...
%! scan_functions (5)
%!error<scan_functions: DIRLIST must be a cell array of character vectors.> ...
%! scan_functions ({1, 2})
%!error<scan_functions: DIRLIST must not be empty.> scan_functions ({})
%!error<scan_functions: 'no_such_dir_here' is not an existing directory.> ...
%! scan_functions ({'no_such_dir_here'})
%!error<is not on the load path. Class detection requires every scanned directory to be reachable.> ...
%! scan_functions ({tempdir()})
