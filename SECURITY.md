# Security policy

Tern runs real programs that talk to real servers, so security matters.

## Reporting a vulnerability

Email daelyn@flowtechnicalsolutions.com with the details. Please do not open a public issue for
anything that could put users at risk until a fix has shipped. You will get a reply within a few
days.

## What is in scope

* The Tern app and the TernCore package in this repository.
* How Tern embeds and configures the third party frameworks (environment variables, certificate
  bundle, file permissions for `~/.ssh`).

Vulnerabilities inside upstream projects (OpenSSH, OpenSSL, libssh2, curl, libgit2, Vim, dash,
ios_system) should be reported to those projects; please tell us too so Tern can update its
pinned binaries.

## Supply chain

Every binary Tern ships is pinned by SHA-256 in `Toolchain/manifest.tsv` and downloaded from the
upstream projects' GitHub releases. The download script refuses anything whose hash does not match.
