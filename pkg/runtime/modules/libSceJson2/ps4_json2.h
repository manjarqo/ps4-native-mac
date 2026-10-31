#ifndef PS4_JSON2_H
#define PS4_JSON2_H

// libSceJson2 (sce::Json) shims; the object model is described in ps4_json2.c.
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include "recomp_runtime.h"

#ifdef __cplusplus
extern "C" {
#endif

void shim__ZN3sce4Json12MemAllocatorC2Ev(GuestContext *ctx);
void shim__ZN3sce4Json12MemAllocatorD2Ev(GuestContext *ctx);
void shim__ZN3sce4Json14InitParameter2C1Ev(GuestContext *ctx);
void shim__ZN3sce4Json14InitParameter212setAllocatorEPNS0_12MemAllocatorEPv(GuestContext *ctx);
void shim__ZN3sce4Json14InitParameter217setFileBufferSizeEm(GuestContext *ctx);
void shim__ZN3sce4Json11InitializerC1Ev(GuestContext *ctx);
void shim__ZN3sce4Json11InitializerD1Ev(GuestContext *ctx);
void shim__ZN3sce4Json11Initializer10initializeEPKNS0_14InitParameter2E(GuestContext *ctx);
void shim__ZN3sce4Json11Initializer9terminateEv(GuestContext *ctx);

void shim__ZN3sce4Json6StringC1Ev(GuestContext *ctx);
void shim__ZN3sce4Json6StringC1EPKc(GuestContext *ctx);
void shim__ZN3sce4Json6StringD1Ev(GuestContext *ctx);
void shim__ZN3sce4Json6StringaSERKS1_(GuestContext *ctx);
void shim__ZNK3sce4Json6String5c_strEv(GuestContext *ctx);
void shim__ZNK3sce4Json6String6lengthEv(GuestContext *ctx);

void shim__ZN3sce4Json5ValueC1Ev(GuestContext *ctx);
void shim__ZN3sce4Json5ValueD1Ev(GuestContext *ctx);
void shim__ZN3sce4Json5ValueC1Eb(GuestContext *ctx);
void shim__ZN3sce4Json5ValueC1El(GuestContext *ctx);
void shim__ZN3sce4Json5ValueC1Ed(GuestContext *ctx);
void shim__ZN3sce4Json5ValueC1EPKc(GuestContext *ctx);
void shim__ZN3sce4Json5ValueC1ERKNS0_6StringE(GuestContext *ctx);
void shim__ZN3sce4Json5ValueC1ERKNS0_6ObjectE(GuestContext *ctx);
void shim__ZN3sce4Json5ValueC1ERKNS0_5ArrayE(GuestContext *ctx);
void shim__ZN3sce4Json5ValueaSERKS1_(GuestContext *ctx);
void shim__ZN3sce4Json5Value3setENS0_9ValueTypeE(GuestContext *ctx);
void shim__ZN3sce4Json5Value3setERKNS0_6ObjectE(GuestContext *ctx);
void shim__ZNK3sce4Json5Value7getTypeEv(GuestContext *ctx);
void shim__ZNK3sce4Json5Value10getBooleanEv(GuestContext *ctx);
void shim__ZNK3sce4Json5Value10getIntegerEv(GuestContext *ctx);
void shim__ZNK3sce4Json5Value7getRealEv(GuestContext *ctx);
void shim__ZNK3sce4Json5Value9getStringEv(GuestContext *ctx);
void shim__ZNK3sce4Json5Value8getArrayEv(GuestContext *ctx);
void shim__ZNK3sce4Json5Value9getObjectEv(GuestContext *ctx);
void shim__ZN3sce4Json5Value10referArrayEv(GuestContext *ctx);
void shim__ZN3sce4Json5Value11referObjectEv(GuestContext *ctx);
void shim__ZNK3sce4Json5ValueixEPKc(GuestContext *ctx);
void shim__ZNK3sce4Json5ValueixEm(GuestContext *ctx);
void shim__ZN3sce4Json5Value9serializeERNS0_6StringE(GuestContext *ctx);

void shim__ZN3sce4Json5ArrayC1Ev(GuestContext *ctx);
void shim__ZN3sce4Json5ArrayD1Ev(GuestContext *ctx);
void shim__ZNK3sce4Json5Array4sizeEv(GuestContext *ctx);
void shim__ZNK3sce4Json5Array5emptyEv(GuestContext *ctx);
void shim__ZNK3sce4Json5Array4backEv(GuestContext *ctx);
void shim__ZN3sce4Json5Array9push_backERKNS0_5ValueE(GuestContext *ctx);

void shim__ZN3sce4Json6ObjectC1Ev(GuestContext *ctx);
void shim__ZN3sce4Json6ObjectC1ERKS1_(GuestContext *ctx);
void shim__ZN3sce4Json6ObjectD1Ev(GuestContext *ctx);
void shim__ZN3sce4Json6Object5clearEv(GuestContext *ctx);
void shim__ZNK3sce4Json6Object5emptyEv(GuestContext *ctx);
void shim__ZN3sce4Json6ObjectaSERKS1_(GuestContext *ctx);
void shim__ZN3sce4Json6ObjectixERKNS0_6StringE(GuestContext *ctx);

void shim__ZN3sce4Json6Parser5parseERNS0_5ValueEPKcm(GuestContext *ctx);

#ifdef __cplusplus
}
#endif

#endif // PS4_JSON2_H
