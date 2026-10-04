#pragma once

#if defined(__APPLE__) && !defined(FEX_IOS_HOST)
#include <cstddef>
#include <cstdint>

// The pinned Arm64.cpp's misaligned-CASP reporter queries Wine's Windows
// memory map unconditionally. That map is unavailable to the native archive.
// Keep the reporter's existing "?" result without changing atomic emulation.
// These names are private to this translation unit's diagnostic namespace.
namespace FEXCore::ArchHelpers::Arm64 {
using LPCVOID = const void*;
struct MEMORY_BASIC_INFORMATION {
  void* BaseAddress;
  std::size_t RegionSize;
  std::uint32_t Protect, Type, State;
};
inline constexpr std::uint32_t MEM_IMAGE = 0x01000000;
inline constexpr std::uint32_t MEM_MAPPED = 0x00040000;
inline std::size_t VirtualQuery(LPCVOID, MEMORY_BASIC_INFORMATION*, std::size_t) { return 0; }
}
#endif
