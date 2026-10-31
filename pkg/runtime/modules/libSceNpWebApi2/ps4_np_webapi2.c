// SPDX-License-Identifier: GPL-2.0-or-later
//
// libSceNpWebApi2: library contexts, user contexts and requests, as shadPS4 keeps them
// (src/core/libraries/np/np_web_api2, Copyright 2024-2026 shadPS4 Emulator Project,
// GPL-2.0-or-later), whose ids and error codes this follows:
//   library context id  1..0x7fff
//   user context id     lib_ctx_id << 16 | n
//   request id          user_ctx_id << 32 | n   (so lib_ctx_id = request_id >> 48)
// The host user is never signed in to PSN (libSceNp reports SignedOut), so a request is created,
// takes headers and can be aborted or deleted, but sending it fails with
// SCE_NP_WEBAPI2_ERROR_NOT_SIGNED_IN, as in shadPS4 without a server. A request that never got a
// response has no data to read (SCE_HTTP_ERROR_INVALID_ID, the error of the HTTP request that
// was never created) and no response headers (SCE_HTTP_ERROR_PARSE_HTTP_NOT_FOUND).
#include "recomp_runtime.h"
#include <pthread.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define WEBAPI2_ERROR_INVALID_ARGUMENT ((int32_t)0x80553402)
#define WEBAPI2_ERROR_INVALID_LIB_CONTEXT_ID ((int32_t)0x80553403)
#define WEBAPI2_ERROR_LIB_CONTEXT_NOT_FOUND ((int32_t)0x80553404)
#define WEBAPI2_ERROR_USER_CONTEXT_NOT_FOUND ((int32_t)0x80553405)
#define WEBAPI2_ERROR_REQUEST_NOT_FOUND ((int32_t)0x80553406)
#define WEBAPI2_ERROR_NOT_SIGNED_IN ((int32_t)0x80553407)
#define WEBAPI2_ERROR_INVALID_CONTENT_PARAMETER ((int32_t)0x80553408)
#define WEBAPI2_ERROR_ABORTED ((int32_t)0x80553409)
#define WEBAPI2_ERROR_USER_CONTEXT_ALREADY_EXIST ((int32_t)0x8055340a)
#define WEBAPI2_ERROR_PARAMETER_TOO_LONG ((int32_t)0x80553416)
#define WEBAPI2_ERROR_LIB_CONTEXT_MAX ((int32_t)0x80553418)
#define WEBAPI2_ERROR_USER_CONTEXT_MAX ((int32_t)0x80553419)
#define WEBAPI2_ERROR_AFTER_SEND ((int32_t)0x8055341a)
#define HTTP_ERROR_INVALID_ID ((int32_t)0x80431100)
#define HTTP_ERROR_PARSE_HTTP_NOT_FOUND ((int32_t)0x80432025)

#define MAX_LIB_CONTEXTS 16
#define MAX_USER_CONTEXTS 16 // per library context

typedef struct Request {
    int64_t id;
    bool sent;
    bool aborted;
    struct Request *next;
} Request;

typedef struct UserContext {
    int32_t id; // 0: free slot
    int32_t user_id;
    uint32_t next_request;
    Request *requests;
} UserContext;

typedef struct LibContext {
    int32_t id; // 0: free slot
    uint32_t next_user;
    UserContext users[MAX_USER_CONTEXTS];
} LibContext;

static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
static LibContext g_libs[MAX_LIB_CONTEXTS];
static int32_t g_next_lib_id;

static LibContext *find_lib(int32_t id) {
    for (int i = 0; i < MAX_LIB_CONTEXTS; i++)
        if (g_libs[i].id && g_libs[i].id == id) return &g_libs[i];
    return NULL;
}

static UserContext *find_user(LibContext *lib, int32_t id) {
    for (int i = 0; i < MAX_USER_CONTEXTS; i++)
        if (lib->users[i].id && lib->users[i].id == id) return &lib->users[i];
    return NULL;
}

static void free_requests(UserContext *u) {
    for (Request *r = u->requests; r;) {
        Request *next = r->next;
        free(r);
        r = next;
    }
    u->requests = NULL;
}

// The request `request_id` (g_lock held), or NULL with *err set.
static Request *find_request(int64_t request_id, int32_t *err) {
    LibContext *lib = find_lib((int32_t)(request_id >> 48));
    if (!lib) {
        *err = WEBAPI2_ERROR_LIB_CONTEXT_NOT_FOUND;
        return NULL;
    }
    UserContext *u = find_user(lib, (int32_t)(request_id >> 32));
    if (!u) {
        *err = WEBAPI2_ERROR_USER_CONTEXT_NOT_FOUND;
        return NULL;
    }
    for (Request *r = u->requests; r; r = r->next)
        if (r->id == request_id) return r;
    *err = WEBAPI2_ERROR_REQUEST_NOT_FOUND;
    return NULL;
}

#define RET(v)                                                                                 \
    do {                                                                                       \
        ctx->rax = (uint64_t)(int64_t)(int32_t)(v);                                            \
        SHIM_RETURN();                                                                         \
        return;                                                                                \
    } while (0)

static const char *gstr(GuestContext *ctx, uint64_t a) { return a ? (const char *)(ctx->mem_base + a) : NULL; }

// int sceNpWebApi2Initialize(int libHttpCtxId, size_t poolSize)
void shim_sceNpWebApi2Initialize(GuestContext *ctx) {
    pthread_mutex_lock(&g_lock);
    LibContext *slot = NULL;
    for (int i = 0; i < MAX_LIB_CONTEXTS && !slot; i++)
        if (!g_libs[i].id) slot = &g_libs[i];
    int32_t rc = WEBAPI2_ERROR_LIB_CONTEXT_MAX;
    if (slot) {
        do {
            g_next_lib_id = g_next_lib_id % 0x7fff + 1;
        } while (find_lib(g_next_lib_id));
        memset(slot, 0, sizeof(*slot));
        slot->id = g_next_lib_id;
        rc = slot->id;
    }
    pthread_mutex_unlock(&g_lock);
    RET(rc);
}

// int sceNpWebApi2Terminate(int libCtxId): deletes its user contexts and their requests.
void shim_sceNpWebApi2Terminate(GuestContext *ctx) {
    pthread_mutex_lock(&g_lock);
    LibContext *lib = find_lib((int32_t)ctx->rdi);
    if (lib) {
        for (int i = 0; i < MAX_USER_CONTEXTS; i++) free_requests(&lib->users[i]);
        memset(lib, 0, sizeof(*lib));
    }
    pthread_mutex_unlock(&g_lock);
    RET(lib ? 0 : WEBAPI2_ERROR_LIB_CONTEXT_NOT_FOUND);
}

// int sceNpWebApi2CreateUserContext(int libCtxId, SceUserServiceUserId userId)
void shim_sceNpWebApi2CreateUserContext(GuestContext *ctx) {
    const int32_t lib_id = (int32_t)ctx->rdi, user_id = (int32_t)ctx->rsi;
    if (lib_id >= 0x8000) RET(WEBAPI2_ERROR_INVALID_LIB_CONTEXT_ID);
    if (user_id == -1) RET(WEBAPI2_ERROR_INVALID_ARGUMENT);
    pthread_mutex_lock(&g_lock);
    int32_t rc;
    LibContext *lib = find_lib(lib_id);
    if (!lib) {
        rc = WEBAPI2_ERROR_LIB_CONTEXT_NOT_FOUND;
    } else {
        UserContext *slot = NULL;
        rc = WEBAPI2_ERROR_USER_CONTEXT_MAX;
        for (int i = 0; i < MAX_USER_CONTEXTS; i++) {
            if (lib->users[i].id && lib->users[i].user_id == user_id) {
                rc = WEBAPI2_ERROR_USER_CONTEXT_ALREADY_EXIST;
                slot = NULL;
                break;
            }
            if (!lib->users[i].id && !slot) slot = &lib->users[i];
        }
        if (slot) {
            lib->next_user = lib->next_user % 0xffff + 1;
            slot->id = lib->id << 16 | (int32_t)lib->next_user;
            slot->user_id = user_id;
            slot->next_request = 0;
            slot->requests = NULL;
            rc = slot->id;
        }
    }
    pthread_mutex_unlock(&g_lock);
    RET(rc);
}

// int sceNpWebApi2DeleteUserContext(int userCtxId): deletes its requests too.
void shim_sceNpWebApi2DeleteUserContext(GuestContext *ctx) {
    const int32_t id = (int32_t)ctx->rdi;
    pthread_mutex_lock(&g_lock);
    int32_t rc = WEBAPI2_ERROR_LIB_CONTEXT_NOT_FOUND;
    LibContext *lib = find_lib(id >> 16);
    if (lib) {
        UserContext *u = find_user(lib, id);
        rc = WEBAPI2_ERROR_USER_CONTEXT_NOT_FOUND;
        if (u) {
            free_requests(u);
            memset(u, 0, sizeof(*u));
            rc = 0;
        }
    }
    pthread_mutex_unlock(&g_lock);
    RET(rc);
}

// int sceNpWebApi2CreateRequest(int userCtxId, const char *apiGroup, const char *path,
//     const char *method, const SceNpWebApi2ContentParameter *contentParameter, int64_t *requestId)
// contentParameter: {size_t contentLength; const char *contentType; ...}
void shim_sceNpWebApi2CreateRequest(GuestContext *ctx) {
    const int32_t user_ctx_id = (int32_t)ctx->rdi;
    const char *group = gstr(ctx, ctx->rsi), *path = gstr(ctx, ctx->rdx), *method = gstr(ctx, ctx->rcx);
    if (!group || !path || !method) RET(WEBAPI2_ERROR_INVALID_ARGUMENT);
    if (ctx->r8) {
        uint64_t len, type;
        memcpy(&len, ctx->mem_base + ctx->r8, 8);
        memcpy(&type, ctx->mem_base + ctx->r8 + 8, 8);
        if (len != 0 && !type) RET(WEBAPI2_ERROR_INVALID_CONTENT_PARAMETER);
    }
    pthread_mutex_lock(&g_lock);
    int32_t rc = WEBAPI2_ERROR_LIB_CONTEXT_NOT_FOUND;
    LibContext *lib = find_lib(user_ctx_id >> 16);
    if (lib) {
        UserContext *u = find_user(lib, user_ctx_id);
        rc = WEBAPI2_ERROR_USER_CONTEXT_NOT_FOUND;
        if (u) {
            rc = WEBAPI2_ERROR_PARAMETER_TOO_LONG;
            if (strlen(group) < 63) {
                Request *r = (Request *)calloc(1, sizeof(Request));
                u->next_request = u->next_request % 0x7fffffffu + 1;
                r->id = (int64_t)((uint64_t)(uint32_t)user_ctx_id << 32 | u->next_request);
                r->next = u->requests;
                u->requests = r;
                if (ctx->r9) memcpy(ctx->mem_base + ctx->r9, &r->id, 8);
                rc = 0;
            }
        }
    }
    pthread_mutex_unlock(&g_lock);
    RET(rc);
}

// int sceNpWebApi2DeleteRequest(int64_t requestId)
void shim_sceNpWebApi2DeleteRequest(GuestContext *ctx) {
    const int64_t id = (int64_t)ctx->rdi;
    pthread_mutex_lock(&g_lock);
    int32_t rc = 0;
    Request *r = find_request(id, &rc);
    if (r) {
        UserContext *u = find_user(find_lib((int32_t)(id >> 48)), (int32_t)(id >> 32));
        for (Request **pp = &u->requests; *pp; pp = &(*pp)->next)
            if (*pp == r) {
                *pp = r->next;
                break;
            }
        free(r);
    }
    pthread_mutex_unlock(&g_lock);
    RET(rc);
}

// int sceNpWebApi2AbortRequest(int64_t requestId)
void shim_sceNpWebApi2AbortRequest(GuestContext *ctx) {
    pthread_mutex_lock(&g_lock);
    int32_t rc = 0;
    Request *r = find_request((int64_t)ctx->rdi, &rc);
    if (r) r->aborted = true;
    pthread_mutex_unlock(&g_lock);
    RET(rc);
}

// int sceNpWebApi2AddHttpRequestHeader(int64_t requestId, const char *name, const char *value)
void shim_sceNpWebApi2AddHttpRequestHeader(GuestContext *ctx) {
    if (!ctx->rsi || !ctx->rdx) RET(WEBAPI2_ERROR_INVALID_ARGUMENT);
    pthread_mutex_lock(&g_lock);
    int32_t rc = 0;
    Request *r = find_request((int64_t)ctx->rdi, &rc);
    if (r && r->sent) rc = WEBAPI2_ERROR_AFTER_SEND;
    pthread_mutex_unlock(&g_lock);
    RET(rc);
}

// int sceNpWebApi2SendRequest(int64_t requestId, const void *data, size_t size,
//                             SceNpWebApi2ResponseInformationOption *respInfoOption)
void shim_sceNpWebApi2SendRequest(GuestContext *ctx) {
    pthread_mutex_lock(&g_lock);
    int32_t rc = 0;
    Request *r = find_request((int64_t)ctx->rdi, &rc);
    if (r) {
        r->sent = true;
        rc = r->aborted ? WEBAPI2_ERROR_ABORTED : WEBAPI2_ERROR_NOT_SIGNED_IN;
    }
    pthread_mutex_unlock(&g_lock);
    static int logged;
    if (rc == WEBAPI2_ERROR_NOT_SIGNED_IN && !logged++)
        fprintf(stderr, "[libSceNpWebApi2] requests fail with NOT_SIGNED_IN: the user is not signed in to PSN\n");
    RET(rc);
}

// int sceNpWebApi2ReadData(int64_t requestId, void *data, size_t size)
void shim_sceNpWebApi2ReadData(GuestContext *ctx) {
    pthread_mutex_lock(&g_lock);
    int32_t rc = 0;
    Request *r = find_request((int64_t)ctx->rdi, &rc);
    if (r) rc = r->aborted ? WEBAPI2_ERROR_ABORTED : HTTP_ERROR_INVALID_ID;
    pthread_mutex_unlock(&g_lock);
    RET(rc);
}

// int sceNpWebApi2GetHttpResponseHeaderValueLength(int64_t requestId, const char *name, size_t *len)
void shim_sceNpWebApi2GetHttpResponseHeaderValueLength(GuestContext *ctx) {
    if (!ctx->rsi || !ctx->rdx) RET(WEBAPI2_ERROR_INVALID_ARGUMENT);
    pthread_mutex_lock(&g_lock);
    int32_t rc = 0;
    if (find_request((int64_t)ctx->rdi, &rc)) rc = HTTP_ERROR_PARSE_HTTP_NOT_FOUND;
    pthread_mutex_unlock(&g_lock);
    RET(rc);
}

// int sceNpWebApi2GetHttpResponseHeaderValue(int64_t requestId, const char *name, char *value,
//                                            size_t size)
void shim_sceNpWebApi2GetHttpResponseHeaderValue(GuestContext *ctx) {
    if (!ctx->rsi || !ctx->rdx || !ctx->rcx) RET(WEBAPI2_ERROR_INVALID_ARGUMENT);
    pthread_mutex_lock(&g_lock);
    int32_t rc = 0;
    if (find_request((int64_t)ctx->rdi, &rc)) rc = HTTP_ERROR_PARSE_HTTP_NOT_FOUND;
    pthread_mutex_unlock(&g_lock);
    RET(rc);
}
