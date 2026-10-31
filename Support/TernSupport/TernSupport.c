// User database fallback.
//
// ssh, scp, sftp, ssh-keygen and whoami all begin with getpwuid(getuid()) and
// exit when it fails ("No user exists for uid 501"). Real devices answer the
// lookup from /etc/passwd, where uid 501 is "mobile". The iOS simulator ships
// no passwd file at all, and nothing guarantees that future systems will keep
// one, so Tern answers the lookup itself whenever the system cannot.
//
// The replacement is installed with dyld interposing: this framework is linked
// by the app binary and therefore loaded at launch, and dyld redirects every
// later binding of getpwuid/getpwnam (including the toolchain frameworks that
// ios_system opens with dlopen) to the functions below. Calls made from inside
// this framework still reach the real libSystem implementation, which is what
// lets the replacements try the system first.

#include "TernSupport.h"

#include <errno.h>
#include <limits.h>
#include <pwd.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define TERN_INTERPOSE(replacement, original)                                   \
    __attribute__((used)) static const struct {                                 \
        const void *replacement;                                                \
        const void *original;                                                   \
    } tern_interpose_##original __attribute__((section("__DATA,__interpose"))) = { \
        (const void *)(unsigned long)&replacement,                              \
        (const void *)(unsigned long)&original,                                 \
    };

static char tern_user_name[] = "mobile";
static char tern_user_password[] = "*";
static char tern_user_class[] = "";
static char tern_user_gecos[] = "Mobile User";
static char tern_user_shell[] = "/bin/sh";
static char tern_user_home[PATH_MAX];
static struct passwd tern_user;

static const char *tern_home_directory(void) {
    const char *home = getenv("HOME");
    if (home == NULL || home[0] == '\0') {
        home = "/";
    }
    return home;
}

static bool tern_is_current_user(uid_t uid) {
    return uid == getuid() || uid == geteuid();
}

static bool tern_is_current_user_name(const char *name) {
    if (name == NULL) {
        return false;
    }
    if (strcmp(name, tern_user_name) == 0) {
        return true;
    }
    const char *user = getenv("USER");
    return user != NULL && user[0] != '\0' && strcmp(name, user) == 0;
}

static struct passwd *tern_fallback_user(uid_t uid) {
    strlcpy(tern_user_home, tern_home_directory(), sizeof(tern_user_home));
    tern_user.pw_name = tern_user_name;
    tern_user.pw_passwd = tern_user_password;
    tern_user.pw_uid = uid;
    tern_user.pw_gid = getgid();
    tern_user.pw_change = 0;
    tern_user.pw_class = tern_user_class;
    tern_user.pw_gecos = tern_user_gecos;
    tern_user.pw_dir = tern_user_home;
    tern_user.pw_shell = tern_user_shell;
    tern_user.pw_expire = 0;
    return &tern_user;
}

// Copies the fallback entry into caller-provided storage, the getpw*_r way.
static int tern_fill_user_r(uid_t uid, struct passwd *pw, char *buffer, size_t size, struct passwd **result) {
    const char *home = tern_home_directory();
    size_t needed = sizeof(tern_user_name) + sizeof(tern_user_password) + sizeof(tern_user_class)
        + sizeof(tern_user_gecos) + sizeof(tern_user_shell) + strlen(home) + 1;
    if (pw == NULL || buffer == NULL || size < needed) {
        if (result != NULL) {
            *result = NULL;
        }
        return ERANGE;
    }
    char *cursor = buffer;
#define TERN_COPY(field, text)                                                  \
    do {                                                                        \
        size_t length = strlen(text) + 1;                                       \
        memcpy(cursor, text, length);                                           \
        pw->field = cursor;                                                     \
        cursor += length;                                                       \
    } while (0)
    TERN_COPY(pw_name, tern_user_name);
    TERN_COPY(pw_passwd, tern_user_password);
    TERN_COPY(pw_class, tern_user_class);
    TERN_COPY(pw_gecos, tern_user_gecos);
    TERN_COPY(pw_dir, home);
    TERN_COPY(pw_shell, tern_user_shell);
#undef TERN_COPY
    pw->pw_uid = uid;
    pw->pw_gid = getgid();
    pw->pw_change = 0;
    pw->pw_expire = 0;
    if (result != NULL) {
        *result = pw;
    }
    return 0;
}

static struct passwd *tern_getpwuid(uid_t uid) {
    struct passwd *pw = getpwuid(uid);
    if (pw != NULL || !tern_is_current_user(uid)) {
        return pw;
    }
    return tern_fallback_user(uid);
}

static struct passwd *tern_getpwnam(const char *name) {
    struct passwd *pw = getpwnam(name);
    if (pw != NULL || !tern_is_current_user_name(name)) {
        return pw;
    }
    return tern_fallback_user(getuid());
}

static int tern_getpwuid_r(uid_t uid, struct passwd *pw, char *buffer, size_t size, struct passwd **result) {
    int status = getpwuid_r(uid, pw, buffer, size, result);
    if ((status == 0 && result != NULL && *result != NULL) || !tern_is_current_user(uid)) {
        return status;
    }
    return tern_fill_user_r(uid, pw, buffer, size, result);
}

static int tern_getpwnam_r(const char *name, struct passwd *pw, char *buffer, size_t size, struct passwd **result) {
    int status = getpwnam_r(name, pw, buffer, size, result);
    if ((status == 0 && result != NULL && *result != NULL) || !tern_is_current_user_name(name)) {
        return status;
    }
    return tern_fill_user_r(getuid(), pw, buffer, size, result);
}

TERN_INTERPOSE(tern_getpwuid, getpwuid)
TERN_INTERPOSE(tern_getpwnam, getpwnam)
TERN_INTERPOSE(tern_getpwuid_r, getpwuid_r)
TERN_INTERPOSE(tern_getpwnam_r, getpwnam_r)

bool tern_passwd_fallback_active(void) {
    return getpwuid(getuid()) == NULL;
}

const char *tern_passwd_fallback_name(void) {
    return tern_user_name;
}
