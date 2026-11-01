import Foundation

/// Text for the `help` command. Kept short and scannable; it is read on a phone.
enum HelpText {
    private static let bold = "\u{1b}[1m"
    private static let dim = "\u{1b}[2m"
    private static let reset = "\u{1b}[0m"

    static func text(for topic: String?) -> String {
        switch topic?.lowercased() {
        case "keys", "keyboard":
            return keyboard
        case "ssh":
            return ssh
        case "git":
            return git
        case "files":
            return files
        case "mount", "mounts", "umount":
            return mount
        case "shell", "scripting":
            return shell
        case "commands", "list":
            return commands
        default:
            return overview
        }
    }

    static var overview: String {
        """
        \(bold)Tern\(reset) is a Unix terminal that runs on your device. Commands are real programs
        compiled for iOS, not an emulator, so they start instantly and work offline.

        \(bold)Everyday\(reset)
          ls, cd, cat, cp, mv, rm, mkdir, grep, sed, awk, find, sort, head, tail, less, tar, curl, jq
        \(bold)Edit\(reset)      vim (or vi), ed, xxd
        \(bold)Network\(reset)   ssh, scp, sftp, ssh-keygen, curl, ping, dig, nslookup, whois, nc
        \(bold)Git\(reset)       lg2 clone/pull/push/commit/log (type \(bold)help git\(reset))
        \(bold)Scripts\(reset)   sh and dash for POSIX scripts, lua, bc, make, awk
        \(bold)App\(reset)       tern (themes, fonts), open, mount, pbcopy, pbpaste, keys, hosts, settings, newtab

        \(bold)Shortcuts\(reset)
          Tab          complete commands and paths (press twice to list)
          Up / Down    history, or search history for what you typed
          Ctrl-R       search history
          Ctrl-C       stop the running command
          Ctrl-D       end input, or exit at an empty prompt
          Ctrl-L       clear the screen
          Right arrow  accept the grey suggestion

        \(bold)More\(reset)      help keys, help ssh, help git, help files, help mount, help shell, help commands
        \(dim)Home is ~ which is this app's Documents folder. Open it in the Files app with: open .
        Other folders, like Downloads, attach under ~/mnt with: mount Downloads\(reset)

        """
    }

    static var keyboard: String {
        """
        \(bold)Keyboard\(reset)

        The bar above the keyboard has esc, tab, ctrl, alt and arrow keys.
          ctrl         latches until the next key: ctrl then c sends Ctrl-C
          alt          latches like ctrl and sends Alt (Meta) combinations
          arrows       press and hold to repeat
          ^C           interrupt the running command
          Swipe the symbol row for | ~ / : quotes and more.

        \(bold)Hardware keyboards\(reset) work as expected, including Ctrl, Option as Alt, and:
          Cmd-T new tab      Cmd-W close tab      Cmd-K clear
          Cmd-1...9 switch tab        Cmd-Shift-[ and ] previous and next tab
          Cmd-+ and Cmd-- change the font size

        \(bold)Line editing\(reset) (emacs style)
          Ctrl-A / Ctrl-E   start / end of line     Alt-B / Alt-F   move by word
          Ctrl-W            delete word backwards   Alt-D           delete word forwards
          Ctrl-K / Ctrl-U   delete to end / start   Ctrl-Y          paste deleted text
          Ctrl-R            search history          Ctrl-_          undo
          Alt-.             insert last argument    !!              repeat last command

        """
    }

    static var ssh: String {
        """
        \(bold)SSH\(reset)

        1. Make a key (once):         ssh-keygen -t ed25519
        2. Show the public key:       cat ~/.ssh/id_ed25519.pub
           Copy it to the clipboard:  pbcopy < ~/.ssh/id_ed25519.pub
        3. Add it on the server (~/.ssh/authorized_keys), then connect:
                                      ssh user@host
        Password logins also work; Tern asks for the password in the terminal.

        \(bold)Shortcuts\(reset)  Put hosts in ~/.ssh/config (Host, HostName, User, Port, IdentityFile)
                   and connect with ssh name. The \(bold)hosts\(reset) command opens a visual list.
        \(bold)Files\(reset)      scp file user@host:path     sftp user@host
        \(bold)Keys\(reset)       The \(bold)keys\(reset) command manages keys without typing paths.

        """
    }

    static var git: String {
        """
        \(bold)Git\(reset)

        Git on Tern is \(bold)lg2\(reset), a command line built on libgit2. \(bold)git\(reset) is an alias for it.

          git clone https://github.com/user/repo.git
          git status            git log            git diff
          git add .             git commit -m "message"
          git pull              git push           git checkout -b feature
          git branch            git fetch          git remote -v

        Over SSH use a key from ~/.ssh (see help ssh). Over HTTPS use a personal access token
        as the password when asked. Pushing and pulling private repos works with both.
        Not available: rebase, submodules, interactive add, bisect.

        """
    }

    static var files: String {
        """
        \(bold)Files\(reset)

        Your home directory ~ is Tern's Documents folder. It appears in the Files app under
        On My iPhone (or iPad) > Tern, so you can drop files in and edit them from other apps.

          open .          show the current folder in Files
          open file.pdf   open a file with another app or share it
          pbcopy < f      copy a file's text to the clipboard
          pbpaste > f     write the clipboard to a file
          curl -O URL     download a file
          tar xzf a.tgz   unpack an archive
          mount Downloads attach a folder from Files at ~/mnt/Downloads (help mount)

        Dotfiles live in ~ too: ~/.ternrc runs when a tab opens, ~/.vimrc configures vim,
        ~/.ssh holds keys and config, ~/.tern_history is your command history.

        """
    }

    static var mount: String {
        """
        \(bold)Mount\(reset)

        Folders outside Tern, such as Downloads, iCloud Drive or another app's folder, can be
        attached under ~/mnt. Pick the folder once; the mount stays across restarts.

          mount Downloads     choose a folder in Files; it appears at ~/mnt/Downloads
          cd ~/mnt/Downloads  work there like in any other directory
          mount               list mounted folders
          umount Downloads    detach it again (nothing inside the folder is deleted)

        iOS only lets an app reach folders you choose yourself, which is why every mount starts
        with the picker. Safari's downloads are in iCloud Drive > Downloads unless you changed
        Settings > Safari > Downloads to On My iPhone. Files in iCloud that have not been downloaded
        show up as .name.icloud; opening them once in Files downloads them.

        """
    }

    static var shell: String {
        """
        \(bold)Shell\(reset)

        The interactive shell is tsh, a POSIX style shell written for Tern. It runs the syntax you
        know: pipes, redirection, variables, if/for/while/case, functions, $(...), $((...)),
        globs, heredocs, aliases, and most bash extensions ([[ ]], brace expansion, local).

          for f in *.txt; do echo "$f: $(wc -l < "$f") lines"; done
          grep -rn TODO . | sort | head
          alias ll='ls -lah'           # put aliases in ~/.ternrc

        Scripts: sh script.sh runs a script with dash, a real POSIX shell. ./script.sh runs it
        with tsh. Arrays and process substitution are not supported yet.

        """
    }

    static var commands: String {
        """
        \(bold)Commands\(reset)

        Type the first letters and press Tab twice to see what is available. Highlights:

        \(bold)Files\(reset)      ls cp mv rm mkdir rmdir ln touch chmod stat du df find tar gzip gunzip compress base64 cksum md5 sha256
        \(bold)Text\(reset)       cat head tail less more grep egrep fgrep sed awk sort uniq tr wc diff xxd ed jq tee xargs
        \(bold)Network\(reset)    ssh scp sftp ssh-keygen ssh-add curl ping ping6 dig host nslookup whois nc telnet ifconfig
        \(bold)Dev\(reset)        vim lg2 (git) lua luac make bc dc jsc dash sh
        \(bold)System\(reset)     env printenv export date uname uptime whoami id sleep stty say open
        \(bold)App\(reset)        tern help mount umount open keys hosts settings newtab pbcopy pbpaste history clear

        """
    }

    static var about: String {
        """
        \(bold)Tern\(reset) version \(SystemEnvironment.appVersion) (\(SystemEnvironment.buildNumber))
        Free and open source, MIT licensed.
        Source: https://github.com/FLoWIsMe/linux-for-ios

        Built on ios_system by Nicolas Holzschuch (BSD), SwiftTerm by Miguel de Icaza (MIT),
        OpenSSH and libssh2, OpenSSL, curl, libgit2, Vim, dash, Lua, jq, GNU bc and make.
        See Settings > Acknowledgements for every license.

        """
    }
}
