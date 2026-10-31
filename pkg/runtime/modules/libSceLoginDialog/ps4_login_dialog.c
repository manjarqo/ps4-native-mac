// SPDX-License-Identifier: GPL-2.0-or-later
//
// libSceLoginDialog: the system dialog that asks which user is playing (a controller without a
// user, a user switch). The host has one user, the initial user of libSceUserService, who is
// always logged in, so the dialog finishes at once with that user chosen.
//
// No reference implementation exists (shadPS4 has none); the contract below is what Sonic
// Origins (CUSA30448) does with it, read from its code:
//   Initialize() after loading sysmodule 0xe2; a non-zero result leaves the dialog unused.
//   Open(param): param is 0x40 bytes {00 size = 0x40, 04 mode, 08.. up to four user ids and an
//     id at 0x28, -1 for none}; 0 -> the game polls, anything else is an error.
//   UpdateStatus() is polled until it returns 3 (FINISHED), then GetResult(result) with a
//     16-byte result the game zeroes on its stack: 00 result (0 = OK, else canceled),
//     04 user id of the chosen user. Only these 8 bytes are written.
//   Terminate() when the game unloads the dialog.
// The user ids in the parameter are not needed to choose: there is only one user.
#include "recomp_runtime.h"
#include "ps4_user_service.h"
#include <pthread.h>
#include <stdbool.h>
#include <stdio.h>

#define LOGIN_DIALOG_ERROR_NOT_INITIALIZED ((int32_t)0x80B80003)
#define LOGIN_DIALOG_ERROR_ALREADY_INITIALIZED ((int32_t)0x80B80004)
#define LOGIN_DIALOG_ERROR_INVALID_STATE ((int32_t)0x80B80006)
#define LOGIN_DIALOG_ERROR_ARG_NULL ((int32_t)0x80B8000D)

enum { STATUS_NONE = 0, STATUS_INITIALIZED = 1, STATUS_RUNNING = 2, STATUS_FINISHED = 3 };

typedef struct LoginDialogResult {
    int32_t result;
    int32_t user_id;
} LoginDialogResult;

static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
static int32_t g_status = STATUS_NONE;

#define LOGIN_RETURN(v)                                                                        \
    do {                                                                                       \
        ctx->rax = (uint64_t)(int64_t)(int32_t)(v);                                            \
        SHIM_RETURN();                                                                         \
    } while (0)

// int sceLoginDialogInitialize(void)
void shim_sceLoginDialogInitialize(GuestContext *ctx) {
    pthread_mutex_lock(&g_lock);
    const int32_t rc = g_status == STATUS_NONE ? 0 : LOGIN_DIALOG_ERROR_ALREADY_INITIALIZED;
    if (rc == 0) g_status = STATUS_INITIALIZED;
    pthread_mutex_unlock(&g_lock);
    LOGIN_RETURN(rc);
}

// int sceLoginDialogOpen(const SceLoginDialogParam *param)
void shim_sceLoginDialogOpen(GuestContext *ctx) {
    if (!ctx->rdi) LOGIN_RETURN(LOGIN_DIALOG_ERROR_ARG_NULL);
    pthread_mutex_lock(&g_lock);
    int32_t rc = 0;
    if (g_status == STATUS_NONE) rc = LOGIN_DIALOG_ERROR_NOT_INITIALIZED;
    else if (g_status == STATUS_RUNNING) rc = LOGIN_DIALOG_ERROR_INVALID_STATE;
    else g_status = STATUS_RUNNING;
    pthread_mutex_unlock(&g_lock);
    if (rc == 0) fprintf(stderr, "[libSceLoginDialog] opened: user 0x%x chosen\n", ORBIS_USER_SERVICE_INITIAL_USER_ID);
    LOGIN_RETURN(rc);
}

// SceCommonDialogStatus sceLoginDialogUpdateStatus(void): a running dialog finishes at once.
void shim_sceLoginDialogUpdateStatus(GuestContext *ctx) {
    pthread_mutex_lock(&g_lock);
    if (g_status == STATUS_RUNNING) g_status = STATUS_FINISHED;
    const int32_t st = g_status;
    pthread_mutex_unlock(&g_lock);
    LOGIN_RETURN(st);
}

// int sceLoginDialogGetResult(SceLoginDialogResult *result)
void shim_sceLoginDialogGetResult(GuestContext *ctx) {
    if (!ctx->rdi) LOGIN_RETURN(LOGIN_DIALOG_ERROR_ARG_NULL);
    pthread_mutex_lock(&g_lock);
    const bool finished = g_status == STATUS_FINISHED;
    pthread_mutex_unlock(&g_lock);
    if (!finished) LOGIN_RETURN(LOGIN_DIALOG_ERROR_INVALID_STATE);
    LoginDialogResult *r = (LoginDialogResult *)(ctx->mem_base + ctx->rdi);
    r->result = 0; // SCE_COMMON_DIALOG_RESULT_OK
    r->user_id = ORBIS_USER_SERVICE_INITIAL_USER_ID;
    LOGIN_RETURN(0);
}

// int sceLoginDialogTerminate(void)
void shim_sceLoginDialogTerminate(GuestContext *ctx) {
    pthread_mutex_lock(&g_lock);
    const int32_t rc = g_status == STATUS_NONE ? LOGIN_DIALOG_ERROR_NOT_INITIALIZED : 0;
    g_status = STATUS_NONE;
    pthread_mutex_unlock(&g_lock);
    LOGIN_RETURN(rc);
}
