// No-op host shims for system services that have no effect on a desktop
// host (crash handlers, store icons, abort/terminate calls). Each returns
// SCE_OK so the guest continues past initialization.
#include "recomp_runtime.h"
#include <stdio.h>

#define NOOP_SHIM(name)                                                        \
  void shim_##name(GuestContext *ctx) {                                        \
    static int warned;                                                         \
    if (!warned) {                                                             \
      warned = 1;                                                              \
      fprintf(stderr, "[ps4-stub] %s -> 0 (no-op)\n", #name);                  \
    }                                                                          \
    ctx->rax = 0;                                                              \
    SHIM_RETURN();                                                             \
  }

NOOP_SHIM(sceCoredumpRegisterCoredumpHandler)
NOOP_SHIM(sceCoredumpWriteUserData)
NOOP_SHIM(sceKernelSync)
NOOP_SHIM(sceRemoteplayTerminate)
NOOP_SHIM(sceNpCommerceShowPsStoreIcon)
NOOP_SHIM(sceNpCommerceHidePsStoreIcon)
NOOP_SHIM(sceNpCommerceDialogUpdateStatus)
NOOP_SHIM(sceNpSetContentRestriction)
NOOP_SHIM(sceNpNotifyPlusFeature)
NOOP_SHIM(sceNpAbortRequest)
NOOP_SHIM(sceNpAuthAbortRequest)
NOOP_SHIM(sceNpWebApiAbortRequest)
NOOP_SHIM(sceNpSnsFacebookAbortRequest)
NOOP_SHIM(sceHttpAbortWaitRequest)
NOOP_SHIM(sceHttpUnsetEpoll)
NOOP_SHIM(sceNetSocketAbort)
