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
## @deftypefn {pkg-functions} {@var{json} =} encodeJSON (@var{value})
##
## Encode a value as JSON, without needing @code{jsonencode}.
##
## @code{@var{json} = encodeJSON (@var{value})} returns a character vector
## holding @var{value} as JSON.  Character vectors become strings, logicals
## become @qcode{true} and @qcode{false}, numbers become numbers, cell arrays
## become arrays, and structures become objects; a structure array becomes an
## array of objects.  @code{NaN} and infinities become @qcode{null}, which is
## the only thing JSON can say about them.
##
## This exists because @code{jsonencode} arrived in Octave 7.1, and the records
## this repository writes are produced under every interpreter from 4.0.0
## upwards.  It is used unconditionally rather than only where the built-in is
## missing: a branch taken only by a sweep of the distant past is a branch
## nobody exercises and nobody remembers, whereas this way every run and every
## test goes through the same code.
##
## The output is not required to match @code{jsonencode} byte for byte, only to
## mean the same thing.  What reads these records normalises them on the way
## into the data set, so spacing and field order carry no meaning.
##
## @seealso{scan_functions, harvest_package}
## @end deftypefn

function json = encodeJSON (value)

  ## Input validation
  if (nargin != 1)
    error ("encodeJSON: invalid number of input arguments.");
  endif

  json = encodeValue (value);

endfunction

## The recursion proper.  Order matters: a character vector is also an array,
## and an empty value is also a cell or a struct, so the narrow tests come
## first.
function out = encodeValue (value)

  if (ischar (value))
    out = encodeString (value);
  elseif (iscell (value))
    out = encodeCell (value);
  elseif (isstruct (value))
    out = encodeStruct (value);
  elseif (islogical (value))
    out = encodeLogical (value);
  elseif (isnumeric (value))
    out = encodeNumeric (value);
  else
    error ("encodeJSON: cannot encode a value of class '%s'.", class (value));
  endif

endfunction

## A character matrix has no JSON spelling, so only a row vector is accepted;
## an empty one is the empty string rather than an empty array.
function out = encodeString (value)

  if (isempty (value))
    out = '""';
    return;
  endif
  if (! isrow (value))
    error ("encodeJSON: only a character vector can be encoded as a string.");
  endif
  out = ['"' escape(value) '"'];

endfunction

## Escaped by hand rather than with regexprep, so that the control characters
## are dealt with by value and not by pattern.
##
## Nearly every string here is a function name or a path and needs no escaping
## at all, so that case is settled with one vectorised test and returned
## untouched.  Character-by-character concatenation is quadratic, and a core
## record carries seventeen hundred names.
function out = escape (in)

  code = double (in);
  if (! any (code < 32 | code == double ('"') | code == double ('\')))
    out = in;
    return;
  endif

  out = '';
  for ii = 1:numel (in)
    ch = in(ii);
    switch (ch)
      case '"'
        out = [out '\"'];
      case '\'
        out = [out '\\'];
      case sprintf ('\n')
        out = [out '\n'];
      case sprintf ('\r')
        out = [out '\r'];
      case sprintf ('\t')
        out = [out '\t'];
      case sprintf ('\b')
        out = [out '\b'];
      case sprintf ('\f')
        out = [out '\f'];
      otherwise
        if (double (ch) < 32)
          out = [out sprintf('\\u%04x', double (ch))];
        else
          ## Anything else passes through, UTF-8 bytes included: they are
          ## already what JSON wants a string to hold.
          out = [out ch];
        endif
    endswitch
  endfor

endfunction

function out = encodeLogical (value)

  if (! isscalar (value))
    out = encodeArray (value, @(x) encodeLogical (x));
    return;
  endif
  if (value)
    out = 'true';
  else
    out = 'false';
  endif

endfunction

## Integers are written as integers so that a version count or a byte size does
## not come back as 3.0000000000000000.
function out = encodeNumeric (value)

  if (isempty (value))
    out = '[]';
    return;
  endif
  if (! isscalar (value))
    out = encodeArray (value, @(x) encodeNumeric (x));
    return;
  endif
  if (isnan (value) || isinf (value))
    out = 'null';
  elseif (value == fix (value) && abs (value) < 2^53)
    out = sprintf ('%d', value);
  else
    out = sprintf ('%.17g', value);
  endif

endfunction

## An empty cell is an empty array, which is what an absent list looks like
## once it has been through the encoder and back.
function out = encodeCell (value)

  if (isempty (value))
    out = '[]';
    return;
  endif
  parts = cell (1, numel (value));
  for ii = 1:numel (value)
    parts{ii} = encodeValue (value{ii});
  endfor
  out = ['[' strjoin(parts, ",") ']'];

endfunction

## A structure array is an array of objects; a scalar structure is one object.
function out = encodeStruct (value)

  if (numel (value) != 1)
    parts = cell (1, numel (value));
    for ii = 1:numel (value)
      parts{ii} = encodeStruct (value(ii));
    endfor
    out = ['[' strjoin(parts, ",") ']'];
    return;
  endif
  names = fieldnames (value);
  parts = cell (1, numel (names));
  for ii = 1:numel (names)
    parts{ii} = [encodeString(names{ii}) ":" encodeValue(value.(names{ii}))];
  endfor
  out = ['{' strjoin(parts, ",") '}'];

endfunction

## Numeric and logical arrays, element by element in column-major order, which
## is the order jsonencode uses for a vector.
function out = encodeArray (value, encoder)

  parts = cell (1, numel (value));
  for ii = 1:numel (value)
    parts{ii} = encoder (value(ii));
  endfor
  out = ['[' strjoin(parts, ",") ']'];

endfunction

%!error<encodeJSON: invalid number of input arguments.> encodeJSON ()
%!error<encodeJSON: cannot encode a value of class 'function_handle'.> ...
%! encodeJSON (@sin)
%!error<encodeJSON: only a character vector can be encoded as a string.> ...
%! encodeJSON (['ab'; 'cd'])

## Every case below is checked against jsonencode itself, which is the only
## definition of "right" that matters here.
%!assert (encodeJSON ('a/b_c'), jsonencode ('a/b_c'))
%!assert (encodeJSON (''), jsonencode (''))
%!assert (encodeJSON (sprintf ('a\nb\t"c"')), jsonencode (sprintf ('a\nb\t"c"')))
%!assert (encodeJSON (['a' char(92) 'b']), jsonencode (['a' char(92) 'b']))
%!assert (encodeJSON (true), jsonencode (true))
%!assert (encodeJSON (false), jsonencode (false))
%!assert (encodeJSON (42), jsonencode (42))
%!assert (encodeJSON (-1.5), jsonencode (-1.5))
%!assert (encodeJSON (NaN), jsonencode (NaN))
%!assert (encodeJSON (Inf), jsonencode (Inf))
%!assert (encodeJSON ({}), jsonencode ({}))
%!assert (encodeJSON ([]), jsonencode ([]))
%!assert (encodeJSON ({'one', 'two'}), jsonencode ({'one', 'two'}))
%!assert (encodeJSON ([1 2 3]), jsonencode ([1 2 3]))
%!assert (encodeJSON ([true false]), jsonencode ([true false]))

%!test
%! S = struct ('name', 'x', 'ok', true, 'count', 3, 'tags', {{'a', 'b'}});
%! assert_equal (encodeJSON (S), jsonencode (S));

## A record as harvest_package actually builds one: nested, mixed, and with the
## empty cells that an absent list leaves behind.
%!test
%! S = struct ('package', 'p', 'version', '1.0.0', 'status', 'ok', ...
%!             'message', '');
%! S.dependencies = {struct('name', 'd', 'version', '2.0')};
%! S.core_shadowing = {};
%! S.resolution = struct ('policy', 'asof', 'asof', '2024-01-01', ...
%!                        'asof_implied', true, 'backfill', false);
%! S.contents = struct ('functions', {{struct('name', 'f', 'type', 'm')}});
%! assert_equal (encodeJSON (S), jsonencode (S));

%!test
%! S(1).a = 'one';
%! S(2).a = 'two';
%! assert_equal (encodeJSON (S), jsonencode (S));
