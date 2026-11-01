# The Tern shell (tsh)

Tern's interactive shell is `tsh`, a POSIX style shell written in Swift that lives in
`Packages/TernCore/Sources/TernCore/Shell`. It runs identically on iOS, macOS and Linux: the same
interpreter that powers the app runs the test suite against real coreutils on a Mac. External
commands are delegated to a `CommandExecutor` (ios_system on iOS, real processes elsewhere); the
language itself, redirections, pipelines and builtins are implemented in `tsh`.

`$SHELL` is `/bin/tsh` and `$0` is `tsh`. Scripts that start with `#!/bin/sh` or `#!/bin/bash` run
through the same interpreter when no real `sh` or `bash` is available, so most portable scripts
work out of the box. If the toolchain provides `dash` or another shell, `sh` and `bash` resolve to
it like any other command.

## Supported syntax

### Words and quoting

* Single quotes, double quotes, backslash escapes, `$'...'` ANSI-C quoting (`\n`, `\t`, `\xHH`,
  `\uHHHH`, `\e`, octal), `$"..."` (treated as plain double quotes).
* Comments with `#`, line continuation with a trailing backslash.
* Tilde expansion: `~`, `~/path`, `~+` (PWD), `~-` (OLDPWD). Also after `=` and `:` in assignments
  (`PATH=~/bin:~/tools`). `~user` is left alone (there is one user on iOS).
* Brace expansion: `{a,b}`, `{1..5}`, `{a..e}`, `{1..10..2}`, `{01..10}`, nested braces, prefix and
  suffix text. Quoted braces and `${...}` are never expanded.

### Parameters

`$name`, `${name}`, positional `$1` to `$9` and `${10}`, `$#`, `$@`, `$*`, `$?`, `$$`, `$!`, `$0`,
`$-`, `$_`. Dynamic variables: `RANDOM`, `LINENO`, `SECONDS`, `EPOCHSECONDS`, `EPOCHREALTIME`,
`PWD`, `OLDPWD`, `FUNCNAME`.

| Form | Meaning |
| --- | --- |
| `${v:-word}` `${v-word}` | default when unset (or empty with `:`) |
| `${v:=word}` `${v=word}` | assign default |
| `${v:?msg}` `${v?msg}` | error when unset |
| `${v:+word}` `${v+word}` | alternate value |
| `${#v}` `${#@}` | length, number of positional parameters |
| `${v#pat}` `${v##pat}` | remove shortest or longest prefix |
| `${v%pat}` `${v%%pat}` | remove shortest or longest suffix |
| `${v/pat/rep}` `${v//pat/rep}` `${v/#pat/rep}` `${v/%pat/rep}` | replace first, all, prefix, suffix |
| `${v:off}` `${v:off:len}` `${@:off:len}` | substrings and positional slices, negative offsets allowed |
| `${v^}` `${v^^}` `${v,}` `${v,,}` | case conversion |
| `${!v}` `${!prefix*}` `${!prefix@}` | indirection, names with a prefix |

Word splitting follows `IFS` (unset means space, tab, newline). Quoted expansions are never split
or globbed. `"$@"` expands to one word per positional parameter and to nothing when there are none.

### Command substitution and arithmetic

`$(command)` and backticks, nested to any depth. `$((expression))`, `(( expression ))` as a
command, and `let`. Arithmetic is 64 bit with C semantics: `+ - * / % **`, comparisons, logical
`&& || !`, bitwise `& | ^ ~ << >>`, ternary `?:`, assignment operators (`= += -= *= /= %= <<= >>=
&= ^= |=`), `++` and `--` (prefix and postfix), the comma operator, parentheses, decimal, `0x`
hex, `0` octal and `base#digits` literals. Variables are resolved by name and may themselves hold
expressions.

### Pathname expansion

`*`, `?`, `[...]` with ranges, negation (`[!x]`, `[^x]`) and POSIX classes (`[[:alpha:]]`), and
`**` for recursive matching. Hidden files only match patterns that start with a literal dot. A
pattern that matches nothing stays literal (bash default). `set -f` disables globbing. Patterns
are resolved against the session's working directory, never the process directory.

### Commands and control flow

* Pipelines (`|`, `|&`), `;`, newlines, `&&`, `||`, `!` negation, `time` prefix, `&` background jobs.
* `if / elif / else / fi`, `for name in words`, `for name` (positional parameters),
  `for ((init; cond; step))`, `while`, `until`, `case` with `;;`, `;&` and `;;&`, `{ ...; }`,
  `( ... )`, `[[ ... ]]`, `(( ... ))`.
* Functions: `name() compound-command` and `function name compound-command`, `local`, `return`,
  recursion up to 256 levels, `$FUNCNAME`.
* `[[ ]]` supports `== = != < >`, pattern matching on the right hand side of `==` and `!=`,
  `=~` with regular expressions (`BASH_REMATCH` holds the whole match and `BASH_REMATCH_1`,
  `BASH_REMATCH_2`... the groups, since arrays are not available), the numeric operators,
  file tests, `-v name`, `-o option`, `&&`, `||`, `!` and parentheses.

### Redirections

`<`, `>`, `>|`, `>>`, `<>`, `n>`, `n>>`, `n<`, `n>&m`, `n<&m`, `>&-`, `<&-`, `&>`, `&>>`, heredocs
(`<<EOF`, `<<-EOF` strips leading tabs, a quoted delimiter disables expansion), herestrings
(`<<<`). `/dev/stdin`, `/dev/stdout`, `/dev/stderr`, `/dev/fd/N` and `/dev/tty` map onto the
current descriptors so they work inside the iOS sandbox. `set -C` (noclobber) is honoured.
`exec n<file` keeps a descriptor open for the rest of the session.

Every redirection is resolved to a descriptor before the command runs and handed to the command;
the shell never changes the process's own standard descriptors.

### Builtins

`:`, `.`, `[`, `alias`, `bg` (reports that job control is unavailable), `break`, `builtin`, `cd`
(with `-`, `CDPATH`), `clear`, `command` (`-v`, `-V`), `continue`, `declare`/`typeset` (`-x`, `-r`,
`-p`, `-g`, `-f`; `-a` and `-A` report that arrays are unsupported), `dirs`, `echo` (`-n`, `-e`,
`-E`), `eval`, `exec`, `exit`, `export` (`-n`, `-p`), `false`, `fg`, `getopts`, `hash`, `help`,
`history`, `jobs`, `kill` (`-l`, job specs), `let`, `local`, `popd`, `printf` (`%s %d %i %u %o %x
%X %c %e %E %f %g %G %b %q %%`, flags, width, precision, `*` widths, `-v var`, format reuse),
`pushd`, `pwd` (`-P`), `read` (`-r`, `-p`, `-s`, `-d`, `-n`, `-t`), `readonly`, `return`, `set`
(`-e -x -u -f -C -a -v`, `-o pipefail`, `--`, listing variables), `shift`, `source`, `test`, `times`,
`trap` (`EXIT` and `INT` handlers run; other signals are recorded), `true`, `type` (`-t`, `-a`,
`-p`), `ulimit`, `umask`, `unalias`, `unset` (`-v`, `-f`), `wait`, `which`.

`help`, `history` and `clear` are forwarded to the host application first (the terminal owns
history and the screen); `clear` falls back to printing the clear screen sequence. The app adds
its own commands the same way: `tern`, `open`, `mount`, `umount`, `pbcopy`, `pbpaste`, `keys`,
`hosts`, `settings`, `newtab`, `about`.

A few coreutils that the toolchain lacks are builtins too, with the everyday options: `cut`
(`-b`, `-c`, `-f`, `-d`, `-s`, `--output-delimiter`, `--complement`), `seq` (`-s`, `-w`, `-f`,
decimals), `yes`, `rev`, `tac`, `mktemp` (`-d`, `-t`, `-q`, templates), `realpath` (`-e`, `-m`,
`-q`) and `tty`. They read named files or standard input like the originals.

### Options

`set -e` (errexit, with the usual exceptions for conditions, `&&`/`||` lists and `!`), `set -x`
(xtrace with `+ ` prefixes), `set -u` (nounset), `set -f` (noglob), `set -C` (noclobber), `set -a`
(allexport), `set -v`, `set -o pipefail`. `$-` reports the enabled flags.

### Jobs

`command &` runs the pipeline on a background thread. `$!` returns the job number, `wait` waits for
all or one job, `jobs` lists them, `kill %1` interrupts one. Background jobs never read the
keyboard. There is no job control beyond this (`bg`, `fg` and Ctrl-Z are not available: a
background job cannot be brought back to the foreground).

### Diagnostics

Messages follow the shell convention: `tsh: name: command not found`, `tsh: line 3: syntax error
near unexpected token `fi'`, `tsh: cd: dir: No such file or directory`. A command that is not
found suggests the closest known command (`Did you mean: echo?`). Syntax errors return 2,
missing commands 127, interrupted programs 130.

## How it differs from bash

* Arrays (`a=(1 2)`, `${a[0]}`, `declare -a`) are not supported in version 1 and produce a clear
  error. `BASH_REMATCH` groups are exposed as `BASH_REMATCH_n` variables.
* `select`, process substitution (`<(cmd)`, `>(cmd)`), coprocesses, `${var@Q}` transformations,
  extended globs (`extglob`), `shopt`, `history` expansion (`!!`, `!$`) in the interpreter itself
  (the line editor offers history features), and `~user` are not available.
* Every pipeline stage, including the last one, runs in a subshell (bash without `lastpipe`), so
  `echo x | read v` does not set `v` in the parent shell.
* Signals other than `EXIT` and `INT` are recorded by `trap` but never fire: commands run as
  threads inside one process, so there is no process level signal delivery.
* `time` reports wall clock time only.
* `ulimit`, `umask` and `times` report fixed, informational values.
* Interactive `exit` in the middle of a line stops that line; scripts and `-c` strings behave like
  separate shells: `exit` ends the script, `set -e` ends the script, and only exported variables
  are inherited.

## Running the tests

```sh
cd Packages/TernCore
swift test
```

The suite covers every feature above with the real `ProcessCommandExecutor` and, on macOS, runs a
set of portable snippets through both `tsh` and `/bin/sh` and compares the output byte for byte.
