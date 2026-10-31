# Tern architecture

Tern is a native iOS terminal. It does not emulate a Linux kernel or an x86 CPU. Instead it runs a
real POSIX style shell written in Swift and a toolchain of Unix programs compiled for iOS as
dynamic frameworks (the ios_system ecosystem). This is the same approach a-Shell uses and it is
what makes the app fast, offline capable and acceptable to App Review.

```
+-------------------------------------------------------------------+
|  Tern.app (SwiftUI + UIKit)                                        |
|                                                                   |
|  TerminalScreen  TabBar  KeyboardBar  Onboarding  Settings  Hosts  |
|        |                                                          |
|  TerminalView (SwiftTerm)  <---- bytes ----  ShellSession         |
|        |  keystrokes ------------------------>   |  (TernCore)    |
|        |                                         |                |
|  IOSSystemExecutor  <--- ExternalCommand ---  Shell (interpreter) |
|        |                                                          |
|  ios_system.framework  --dlopen-->  files, text, shell, tar, awk, |
|                                     curl, ssh, vim, lg2, dash...  |
+-------------------------------------------------------------------+
```

## Packages

| Path | What it is |
| --- | --- |
| `Packages/TernCore` | Pure Swift, Foundation only. Shell interpreter, line editor, completion, history, highlighting, prompt, and `ShellSession` which ties them together. Builds and tests on macOS and Linux. |
| `Toolchain/frameworks/ios_system.xcframework` | Downloaded by the fetch script and linked by Xcode directly. |
| `Toolchain/manifest.tsv` | Every other prebuilt command framework with its download URL and SHA-256. |
| `scripts/fetch-toolchain.sh` | Downloads and verifies the frameworks into `Toolchain/frameworks` (git ignored). |
| `scripts/embed-toolchain.py` | Xcode build phase: copies the right slice of each framework into `Tern.app/Frameworks` and signs it. |
| `Tern/` | The iOS app. |
| `Support/TernSupport` | A tiny C framework the app links, so it loads before any toolchain framework. It carries launch-time shims the tools need from the OS (see below). |
| `project.yml` | XcodeGen spec that produces `Tern.xcodeproj`. |

## TernCore

### Shell (`Sources/TernCore/Shell`)

`Shell` parses and runs programs. It owns variables, functions, aliases, options and the working
directory of a session. The language is the POSIX shell plus the bash features people actually
use (`[[ ]]`, `$(( ))`, brace expansion, `local`, `function`, herestrings). See `docs/SHELL.md`.

External commands are delegated to a `CommandExecutor`:

* `IOSSystemExecutor` (in the app) runs commands with ios_system.
* `ProcessCommandExecutor` (macOS and Linux) spawns real processes. Tests use it, so the
  interpreter is exercised against real coreutils on every CI run.

The interpreter never calls `fork` or `exec` and never changes the process working directory
for its own needs: every path is resolved against the session's working directory, and the
directory is passed to the executor with each command. ios_system keeps a per session directory
and performs the process level `chdir` right before running a command.

Pipelines are built with POSIX pipes. Each stage runs on its own thread. Stages that are
builtins or compound commands run in a copied interpreter state (subshell semantics), external
stages go to the executor. Redirections are resolved to descriptors before a command runs and
handed over in `ExternalCommand` or `ShellIO`; no descriptor of the process is ever `dup2`ed.

### Line editor (`Sources/TernCore/LineEditor`)

A readline/fish class editor that works on bytes: it parses key sequences, keeps the buffer,
cursor, kill ring, undo stack and history position, and renders the prompt plus the line as a
sequence of terminal escape codes. It supports emacs key bindings, incremental reverse search,
tab completion with a candidate listing, fish style autosuggestions from history, and syntax
highlighting. The renderer handles wrapping across rows, wide characters and prompts that
contain escape sequences.

### Session (`Sources/TernCore/Session`)

`ShellSession` owns:

* the shell thread (runs `Shell.run`, blocks while commands execute),
* one output pipe shared by the shell, builtins, commands and the line editor; a drain thread
  forwards bytes in order to the `TerminalOutputSink` (the app feeds them to SwiftTerm),
* the keyboard router. In `prompt` mode bytes go to the line editor. While an external command
  runs, `CommandExecutor.inputRouting()` decides: `cooked` (local line editing, the finished line
  goes to the command's stdin pipe), `raw` (every byte goes to stdin, used by vim, less, ssh) or
  `rawToDescriptor` (ios_system's tty pipe, used by password prompts).

Interactive commands are detected by ios_system itself, which calls back into the app through
`startInteractive` / `stopInteractive` (C symbols exported from the app with `@_cdecl`). The app
forwards them to `ShellSession.setRawInput`.

## The iOS app

* `IOSSystemExecutor` wraps ios_system: switches to the session (`ios_switchSession`), sets the
  thread streams (`thread_stdin`, `thread_stdout`, `thread_stderr` through a small C shim because
  Swift cannot assign C thread local variables), passes the window size, and quotes arguments the
  way ios_system's own `concatenateArgv` does so no second round of expansion happens.
* `TerminalScreen` hosts a SwiftTerm `TerminalView` per session and the custom keyboard bar.
* Everything the user sees is themed through `Theme`: a light and a dark variant for the chrome
  plus a set of 16 ANSI colors, background, foreground and cursor color for the terminal.
* Home is the Documents folder. `$HOME`, `~`, the Files app and the prompt's `~` all mean the
  same directory, and dotfiles (`.ternrc`, `.vimrc`, `.ssh`, `.gitconfig`) live in it where the
  user can see them. The a-Shell ecosystem assumes the opposite (HOME at the sandbox root,
  files in `$HOME/Documents`), and the prebuilt vim, lg2 and OpenSSH binaries bake
  `Documents/` into their default paths. `scripts/embed-toolchain.py` rewrites those string
  constants in place when it copies the frameworks (shorter strings, NUL padded, only in the
  `__TEXT` string sections), and `scripts/build-ssh.sh` / `scripts/build-vim.sh` make the same
  change at source level for frameworks built locally.
* `TernSupport` uses dyld interposing to answer `getpwuid`/`getpwnam` with a synthesized
  `mobile` user whenever the system user database cannot resolve the process user. ssh, scp,
  sftp, ssh-keygen and whoami all start with that lookup and refuse to run without it; devices
  have `/etc/passwd`, the Simulator does not. The shim tries the system first and only fills in
  for the current uid, so a real entry always wins.

## Threading summary

| Thread | Work |
| --- | --- |
| main | UI, SwiftTerm rendering, keyboard routing, line editor |
| shell thread (per session) | interpreter, blocking waits for input lines, blocking external commands |
| pipeline workers | one per concurrent pipeline stage |
| drain thread (per session) | reads the session output pipe, forwards to the terminal |
| ios_system command threads | created by ios_system for each command |

## Why not emulate Linux?

iOS forbids `fork`/`exec`, JIT compilation and loading unsigned code. An x86 interpreter (iSH's
approach) is a multi year engineering effort, runs slowly, and has been pulled from the App Store
before. Running native binaries compiled for iOS is fast and reliable. The trade off is that only
the bundled commands exist: there is no `apt`. The roadmap keeps a Linux emulation mode as a
possible later addition for people who need arbitrary binaries.
