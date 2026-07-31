#pragma once
#include <cstdint>
#include <vector>
#include <mutex>
#include "Types.h"

namespace API::OM {

struct ObjectInfo {
    uint64_t guid = 0;
    uintptr_t ptr = 0;
    Types::ObjectType type = Types::None;
    int entry = 0;
    Vec3 pos{};
    float facing = 0.f;
};

// Snapshot of visible objects (refreshed by Refresh())
const std::vector<ObjectInfo>& Snapshot();
void Refresh();
size_t Count();
const ObjectInfo* GetByIndex(size_t index); // 1-based for Lua parity optional
const ObjectInfo* GetByGuid(uint64_t guid);
size_t CountByType(Types::ObjectType type);
const ObjectInfo* GetByTypeIndex(Types::ObjectType type, size_t index); // 1-based

uint64_t LocalPlayerGuid();
uintptr_t LocalPlayerPtr();

} // namespace API::OM
