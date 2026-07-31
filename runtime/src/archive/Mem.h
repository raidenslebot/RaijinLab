#pragma once
#include <cstdint>
#include <cstring>

namespace Mem {

template <typename T>
inline T Read(uintptr_t address) {
    if (!address)
        return T{};
    return *reinterpret_cast<T*>(address);
}

template <typename T>
inline bool Write(uintptr_t address, const T& value) {
    if (!address)
        return false;
    *reinterpret_cast<T*>(address) = value;
    return true;
}

inline bool IsPlausiblyReadable(uintptr_t p) {
    // coarse user-mode pointer check (x86)
    return p >= 0x10000 && p < 0x7FFF0000;
}

} // namespace Mem
