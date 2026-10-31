# Tern support

Thanks for using Tern. Here is how to get help and how to report problems.

## Quick answers

* **Where are my files?** Home (`~`) is the app's Documents folder. Open the Files app and look under
  On My iPhone (or iPad) > Tern. Type `open .` in Tern to jump there.
* **How do I press Ctrl-C?** Tap `ctrl` on the key bar, then `c`. Or tap the red `^C` key.
* **How do I log in with a key?** Type `keys` to generate one, copy the public key, add it to the
  server's `~/.ssh/authorized_keys`, then `ssh user@host`. Type `help ssh` for the full walkthrough.
* **Why does `apt` not exist?** Tern is not a Linux virtual machine. It runs native iOS builds of
  Unix programs. The command list is fixed per release; type `help commands` to see it.
* **Vim says `E1187`, or has no colors.** Report it, that means the runtime files failed to load.
  `vim --version` and `echo $VIMRUNTIME` help us diagnose it.
* **A command exists but says it is not included in this build.** You are running a Simulator
  build on an Apple silicon Mac. Device builds include every command.

## Report a bug or ask a question

Open an issue at https://github.com/FLoWIsMe/linux-for-ios/issues. Include your device, iOS
version, the Tern version (Settings > About) and the exact command you ran. For anything you
would rather not post publicly, email daelyn@flowtechnicalsolutions.com.

## Feature requests

Issues are welcome for those too. Tern is open source under the MIT license; pull requests are
the fastest way to get something in.
