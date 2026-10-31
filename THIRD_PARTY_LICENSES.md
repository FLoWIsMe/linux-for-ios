# Third party software in Tern

Tern's own source code is MIT licensed (see LICENSE). The app bundle also contains prebuilt
binaries from the projects below, downloaded by `scripts/fetch-toolchain.sh` from the URLs in
`Toolchain/manifest.tsv`. Each project keeps its own license; this file records the notices.
Where a license requires it, the corresponding source is available from the linked upstream
repositories, which contain the exact revisions used to build these binaries.

## ios_system (and its awk, curl_ios, files, shell, ssh_cmd, ssh_cmdA, ssh_agent, tar, text frameworks)

Copyright (c) 2017 Nicolas Holzschuch. BSD 3-Clause License.
https://github.com/holzschu/ios_system

Redistribution and use in source and binary forms, with or without modification, are permitted
provided that the following conditions are met: 1. Redistributions of source code must retain the
above copyright notice, this list of conditions and the following disclaimer. 2. Redistributions
in binary form must reproduce the above copyright notice, this list of conditions and the
following disclaimer in the documentation and/or other materials provided with the distribution.
3. Neither the name of the copyright holder nor the names of its contributors may be used to
endorse or promote products derived from this software without specific prior written permission.
THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR
IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND
FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR
CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER
IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT
OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

The files, shell and text frameworks contain BSD utilities from Apple's open source releases
(file_cmds, shell_cmds, text_cmds, adv_cmds) and from FreeBSD, under BSD 2-Clause and 3-Clause
licenses and the Apple Public Source License 2.0. The tar framework contains libarchive (BSD
2-Clause). The awk framework contains the One True AWK (MIT style license by Lucent Technologies).

## SwiftTerm

Copyright (c) 2019-2026 Miguel de Icaza and contributors. MIT License.
https://github.com/migueldeicaza/SwiftTerm

## OpenSSH (ssh, scp, sftp, ssh-keygen, ssh-add, ssh-agent)

Copyright (c) 1995 Tatu Ylonen and the OpenBSD project contributors. BSD style license.
https://www.openssh.com and the iOS port in https://github.com/holzschu/ios_system

## libssh2

Copyright (c) 2004-2024 Sara Golemon, Daniel Stenberg, Simon Josefsson and contributors.
BSD 3-Clause License. https://www.libssh2.org

## OpenSSL

Copyright (c) 1998-2023 The OpenSSL Project. OpenSSL License and SSLeay License (OpenSSL 1.1.1).
This product includes software developed by the OpenSSL Project for use in the OpenSSL Toolkit
(http://www.openssl.org/). This product includes cryptographic software written by Eric Young
(eay@cryptsoft.com). https://www.openssl.org

## curl

Copyright (c) 1996-2026 Daniel Stenberg and contributors. curl license (MIT style).
https://curl.se

## libgit2 (lg2)

Copyright (c) the libgit2 contributors. GNU General Public License version 2 with the linking
exception: "In addition to the permissions in the GNU General Public License, the authors give
you unlimited permission to link the compiled version of this library into combinations with
other programs, and to distribute those combinations without any restriction coming from the use
of this file." The source of the iOS build is at https://github.com/holzschu/libgit2 and
https://github.com/libgit2/libgit2.

## Vim and xxd

Copyright (c) Bram Moolenaar and contributors. Vim license (charityware, GPL compatible).
https://www.vim.org and the iOS port at https://github.com/holzschu/vim. The runtime files in the
app bundle come from Vim 8.1.2424 under the same license.

## dash

Copyright (c) 1989-1994 The Regents of the University of California, (c) 1997-2005 Herbert Xu.
BSD 3-Clause License. http://gondor.apana.org.au/~herbert/dash/

## Lua

Copyright (c) 1994-2024 Lua.org, PUC-Rio. MIT License. https://www.lua.org

## jq

Copyright (c) 2012 Stephen Dolan. MIT License. Includes the Oniguruma regular expression library
(BSD 2-Clause) and decNumber (ICU License). https://jqlang.github.io/jq

## GNU bc and dc

Copyright (c) Free Software Foundation. GNU General Public License version 2 or later.
https://www.gnu.org/software/bc. Source for the iOS build: https://github.com/holzschu/bc

## GNU make

Copyright (c) Free Software Foundation. GNU General Public License version 3 or later.
https://www.gnu.org/software/make. Source for the iOS build is in the ios_system repository.

## network_ios (ping, dig, host, nslookup, whois, nc, telnet, ifconfig, wol)

BSD licensed utilities from FreeBSD and ISC, packaged by Nicolas Holzschuch.
https://github.com/holzschu/network_ios

## Mozilla CA certificate bundle (cacert.pem)

Extracted from Mozilla's NSS by the curl project. Mozilla Public License 2.0.
https://curl.se/docs/caextract.html

## ncurses terminfo entries

The compiled terminfo entries in the app come from macOS and ncurses, MIT style license.

## Color palettes

Solarized (Ethan Schoonover, MIT), Dracula (Zeno Rocha, MIT), Nord (Sven Greb, MIT),
Gruvbox (Pavel Pertsev, MIT), One Dark (Atom contributors, MIT), Catppuccin (MIT).
