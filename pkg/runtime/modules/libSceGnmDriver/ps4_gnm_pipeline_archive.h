// Persistent Metal binary archive of the game's pipelines (their GPU code), so a pipeline built
// in an earlier session loads in about a millisecond. Earlier measurements showed the system
// Metal pipeline cache is not reliable across rebuilds of the game; this archive does not
// depend on it.
#pragma once
#import <Metal/Metal.h>
#include <cstdint>
#include <string>

namespace ps4gnm_pso_archive {
// Opens or creates <dir>/pipelines.metalar and its key index <dir>/pipelines_archived.bin. The
// index starts with a header (OS build, GPU name and registry ID). An archive larger than
// budget_bytes, unreadable, or whose index header differs from this OS/GPU is deleted and a
// new archive started; leftover pipelines.metalar.tmp* files are removed. Returns false (archive disabled) only when Metal cannot create one, or
// with PS4_GNM_NO_PSO_ARCHIVE=1 (only the value "1").
bool Open(id<MTLDevice> dev, const std::string& dir, uint64_t budget_bytes);
bool Enabled();
// Makes pipeline creation look in the archive first (descriptor.binaryArchives).
void Attach(MTLRenderPipelineDescriptor* d);
void Attach(MTLComputePipelineDescriptor* d);
// True if the pipeline with this stable key is in the archive or queued for it.
bool Contains(uint64_t stable_key);
// Adds the pipeline's GPU code to the archive on its queue (the descriptor is copied).
void Add(uint64_t stable_key, MTLRenderPipelineDescriptor* d);
void Add(uint64_t stable_key, MTLComputePipelineDescriptor* d);
// Writes the archive (temporary file + rename) after the queued additions; waits at most
// timeout_s. Returns false on error or timeout.
bool SaveNow(double timeout_s);
// Saves every period_s seconds while there are unsaved additions.
void StartPeriodicSave(double period_s);
} // namespace ps4gnm_pso_archive

// Called by ps4_host_quit (core/recomp_runtime.c, weak reference).
extern "C" void ps4_gnm_pso_archive_save_for_quit(double timeout_s);
