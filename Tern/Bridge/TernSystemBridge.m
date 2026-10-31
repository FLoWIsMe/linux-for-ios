#import "TernSystemBridge.h"
#import <ios_system/ios_system.h>

void tern_set_thread_streams(FILE *input, FILE *output, FILE *error, const void *context) {
    thread_stdin = input;
    thread_stdout = output;
    thread_stderr = error;
    thread_context = (void *)context;
}

void tern_clear_thread_streams(void) {
    thread_stdin = NULL;
    thread_stdout = NULL;
    thread_stderr = NULL;
    thread_context = NULL;
}

const void *tern_thread_context(void) {
    return thread_context;
}
