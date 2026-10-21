#ifndef PTRAUTH_HELPERS_H
#define PTRAUTH_HELPERS_H

#if __arm64e__
#include <ptrauth.h>
#endif

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunused-function"

static void *make_sym_callable(void *ptr) {
#if __arm64e__
    if (!ptr) return ptr;
    ptr = ptrauth_sign_unauthenticated(ptrauth_strip(ptr, ptrauth_key_function_pointer), ptrauth_key_function_pointer, 0);
#endif
    return ptr;
}

static void *make_sym_readable(void *ptr) {
#if __arm64e__
    if (!ptr) return ptr;
    ptr = ptrauth_strip(ptr, ptrauth_key_function_pointer);
#endif
    return ptr;
}

#pragma clang diagnostic pop
#endif
