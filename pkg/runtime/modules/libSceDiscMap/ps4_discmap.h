#ifndef PS4_DISCMAP_H
#define PS4_DISCMAP_H

#include "recomp_runtime.h"

#ifdef __cplusplus
extern "C" {
#endif

void shim_sceDiscMapIsRequestOnHDD(GuestContext *ctx);
void shim_sceDiscMapGetPackageSize(GuestContext *ctx);
void shim_sceDiscMap_8A828CAEE7EDD5E9(GuestContext *ctx);
void shim_Func_7C980FFB0AA27E7A(GuestContext *ctx);
void shim_Func_8A828CAEE7EDD5E9(GuestContext *ctx);
void shim_Func_E7EBCE96E92F91F8(GuestContext *ctx);

#ifdef __cplusplus
}
#endif

#endif // PS4_DISCMAP_H
