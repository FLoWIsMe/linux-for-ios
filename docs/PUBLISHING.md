# Publishing Tern to the App Store

This is the complete path from a clean checkout to a build on the App Store. Steps marked
**(account owner)** need the Apple Developer account holder; everything else can be scripted.

## One time setup

1. **(account owner)** Create the app record in App Store Connect: My Apps > + > New App.
   Platform iOS, name `Tern: Linux Terminal`, primary language English (U.S.), bundle id
   `com.daelyndoughty.tern` (register it under Certificates, Identifiers & Profiles if it is not
   offered in the list), SKU `tern-ios`, full access. The App Store Connect API cannot create app
   records, so this is a manual step.
2. **(account owner)** Make sure an App Store Connect API key with the App Manager role exists
   (Users and Access > Integrations > App Store Connect API). Note the Key ID and Issuer ID and keep
   the `.p8` file in `~/.appstoreconnect/private_keys/`.
3. Fill in the listing from `fastlane/metadata`: description, subtitle, keywords, promotional
   text, support URL, marketing URL and privacy policy URL. Category Developer Tools, secondary
   Utilities. Price free. Availability all countries.
4. App privacy: answer "No, we do not collect data from this app". Tern has no analytics.
5. Age rating: answer no to everything. It comes out as 4+.
6. Export compliance: Tern contains OpenSSL and OpenSSH, so answer that the app uses encryption,
   that it is not limited to Apple's own frameworks, and that it uses standard algorithms. Submit
   the annual self classification report to the US Bureau of Industry and Security if your account
   has not done so this year (the App Store Connect flow links to the form). An alternative is to
   rely on the open source exemption, which requires emailing the source URL to BIS and NSA; the
   first option is simpler. Tick "Yes" for availability in France if asked; Tern is a general
   purpose tool and needs no French import declaration beyond the standard one.
7. Screenshots: run `scripts/export-screenshots.sh` on a Mac with the Simulator. It drives the UI
   tests on an iPhone 6.9 inch and an iPad 13 inch simulator and drops PNGs in
   `fastlane/screenshots/en-US`. Upload the iPhone and iPad sets. Framed marketing screenshots are
   optional; the raw ones are accepted.

## Every release

1. Bump `MARKETING_VERSION` in `project.yml` (and regenerate with `xcodegen generate`) when the
   version changes. The build number is passed on the command line.
2. Archive and upload:

   ```sh
   scripts/release.sh --key-id KEYID --issuer-id ISSUER --build-number 42
   ```

   This fetches the toolchain if needed, archives a Release build for devices, exports it for the
   App Store with automatic (cloud managed) signing and uploads it. Processing takes 5 to 15
   minutes; the build then appears under TestFlight. On a Mac where the account owner is signed
   in to Xcode (Xcode > Settings > Accounts) the key arguments can be left out and Xcode uses that
   account instead.

   The same thing runs from GitHub Actions: Actions > Release to TestFlight > Run workflow, with
   `ASC_KEY_ID`, `ASC_ISSUER_ID` and `ASC_KEY_P8` stored as repository secrets.
3. TestFlight: add the build to an internal group and install it on a device. Check that `vim`,
   `ssh`, `lg2 clone` and `curl https://example.com` work, that the keyboard bar shows and that
   light and dark palettes render correctly.
4. In App Store Connect, create the version, pick the build, paste the release notes from
   `fastlane/metadata/en-US/release_notes.txt`, keep the review notes from
   `fastlane/metadata/review_information/notes.txt`, and submit.

## Toolchain binaries (optional)

Every build downloads the prebuilt command frameworks listed in `Toolchain/manifest.tsv` and
fixes their home directory paths while embedding them (see `docs/ARCHITECTURE.md`). Nothing
has to be compiled. Two scripts build newer versions from source when wanted:

* `scripts/build-ssh.sh` rebuilds ssh, scp, sftp, ssh-keygen and ssh-agent from the ios_system
  sources in about a minute.
* `scripts/build-vim.sh` builds Vim 8.2 with an Apple silicon Simulator slice (the prebuilt Vim
  is 8.1 and has none) in about ten minutes.

Both write to `Toolchain/local/`, which the embed step prefers over the downloads. The
"Build toolchain" GitHub Actions workflow runs both on a macOS runner and attaches the results
to a release; its log prints the manifest lines (URL and SHA-256) to paste into
`Toolchain/manifest.tsv` if the project should start downloading them instead.

## Review notes

Apps that run code have a history with App Review. Tern follows the model a-Shell has used on
the App Store since 2020: every program is compiled into the bundle as a signed framework, nothing
executable is downloaded, and the only interpreted content is the user's own shell scripts and
commands, which guideline 2.5.2 allows. The review notes say exactly that and point at the source.
If a reviewer asks for a demo, `help`, `ls`, `echo hello`, `vim test.txt` and `ssh` with no
arguments are enough to show the app working without any server.

## After approval

* Tag the commit (`v1.0.0`) and create a GitHub release with the same notes.
* Update the README screenshot section and the TestFlight link.
