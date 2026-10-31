# Contributing to Tern

Thank you for helping. Tern is small enough that one person can understand all of it; please keep
it that way.

## Ground rules

* Read `docs/ARCHITECTURE.md` before changing how sessions, the shell or the toolchain fit together.
* `Packages/TernCore` must stay free of UIKit and SwiftUI. It builds on Linux; CI checks that.
* Every change to the interpreter or the line editor comes with tests in `Packages/TernCore/Tests`.
* The app must build with `CODE_SIGNING_ALLOWED=NO` for the Simulator so CI can check it.
* No em dashes in code, comments or docs. No emoji in the UI.
* Match the existing style: one file per concern, short comments that explain why, clear names.

## Setting up

```sh
git clone https://github.com/FLoWIsMe/linux-for-ios.git
cd linux-for-ios
scripts/fetch-toolchain.sh
brew install xcodegen      # only if you edit project.yml
open Tern.xcodeproj
```

Create `Config/Local.xcconfig` with your own `TERN_TEAM_ID` and `TERN_BUNDLE_ID` so the project
signs with your account. That file is ignored by git.

## Running tests

* `cd Packages/TernCore && swift test` for the interpreter, line editor and session.
* `xcodebuild test -project Tern.xcodeproj -scheme Tern -destination 'platform=iOS Simulator,name=iPhone 17'`
  for the app's unit tests and UI tests.

## Adding a command

Commands come from prebuilt frameworks listed in `Toolchain/manifest.tsv`. To add one: publish or
locate an xcframework built against ios_system, add a line with its URL and SHA-256, add the
command to `Tern/Resources/commandDictionary.plist` (framework path, entry symbol, getopt string,
argument type), add its license to `THIRD_PARTY_LICENSES.md` and mention it in `help commands`.

## Pull requests

Keep them focused. Describe what changed and how you tested it. CI must pass.
