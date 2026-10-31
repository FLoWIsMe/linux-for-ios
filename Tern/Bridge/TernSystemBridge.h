#ifndef TernSystemBridge_h
#define TernSystemBridge_h

#include <stdio.h>
#include <stdbool.h>

/// Small C shim over the parts of ios_system that Swift cannot reach directly.
///
/// ios_system keeps the standard streams of the current command in C thread local
/// variables (`thread_stdin`, `thread_stdout`, `thread_stderr`, `thread_context`). Swift
/// cannot assign thread local C variables, so the executor sets them through these helpers
/// right before calling `ios_system` on a worker thread.

/// Sets the thread local streams and context used by the next `ios_system` call on this thread.
void tern_set_thread_streams(FILE *input, FILE *output, FILE *error, const void *context);

/// Clears the thread local streams (restores ios_system's session level defaults).
void tern_clear_thread_streams(void);

/// Returns the thread local context pointer of the calling thread (NULL if unset).
const void *tern_thread_context(void);

#endif /* TernSystemBridge_h */
