// TernSupport: a tiny C framework loaded at launch, ahead of every toolchain
// framework. It provides fallbacks that the Unix tools expect from the OS but
// that iOS does not always supply (see TernSupport.c).

#ifndef TERN_SUPPORT_H
#define TERN_SUPPORT_H

#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Returns true when the system user database could not resolve the current
/// user and TernSupport is answering getpwuid/getpwnam lookups itself.
bool tern_passwd_fallback_active(void);

/// The user name reported to tools when the fallback is active.
const char *tern_passwd_fallback_name(void);

#ifdef __cplusplus
}
#endif

#endif
