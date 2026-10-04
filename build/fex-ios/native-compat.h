#pragma once

#if defined(__APPLE__) && !defined(FEX_IOS_HOST)
#include <cstdint>

// Core.cpp reads these Windows-module diagnostic counters unconditionally,
// while their producers and declarations require FEX_IOS_HOST. The native
// archive has neither the EC entry thunks nor the callback capture producer.
namespace FEXCore::Context {
inline constexpr std::uint64_t IosFfsBypassLog[4] {};
inline constexpr std::uint64_t IosCbEntryLog[8] {};
}

// Apple's FEX configuration disables rpmalloc. There can be no remote-free
// snapshot when the native archive uses the system allocator.
struct rpm_cas_snapshot;
extern "C" inline int rpm_cas_snapshot_take(rpm_cas_snapshot*) { return 0; }
#endif
