# Tern privacy policy

Last updated: October 31, 2026

Tern is a terminal app for iPhone and iPad published by Daelyn Doughty. This policy explains what
the app does with your data. The short version: nothing. Tern has no servers, no accounts, no
analytics and no advertising.

## What Tern collects

Tern does not collect, store or transmit any personal data to the developer or to any third party.
The app contains no analytics, crash reporting or advertising frameworks. Apple may share
anonymous crash reports with the developer if you opted into that in iOS Settings; those contain
no file contents or command history.

## What stays on your device

Everything you create in Tern stays in the app's own storage on your device:

* files in the home directory (visible in the Files app under On My iPhone or iPad > Tern),
* command history (`~/.tern_history`),
* shell and editor configuration (`~/.ternrc`, `~/.vimrc`),
* SSH keys, known hosts and host configuration (`~/.ssh`),
* preferences such as theme and font.

Deleting the app deletes all of it. Standard iOS backups (iCloud or Finder) include the app's
files, under Apple's backup protections.

## Network use

Tern only uses the network when you run a command that does, such as `ssh`, `scp`, `curl`, `git`
or `ping`. Those connections go directly from your device to the server you named; the developer
is not involved and cannot see them. Commands that use TLS verify server certificates against
the Mozilla root certificate bundle included in the app.

## Permissions

Tern does not request access to your location, contacts, photos, camera, microphone or
notifications. The clipboard is read only when you run `pbpaste`, paste into the terminal or
import a key, and written only when you copy text or run `pbcopy`.

## Children

Tern is a general purpose developer tool and is not directed at children under 13.

## Changes

If this policy changes, the new version is published at the same address with an updated date.

## Contact

Questions about privacy: open an issue at https://github.com/FLoWIsMe/linux-for-ios/issues or
email daelyn@flowtechnicalsolutions.com.
