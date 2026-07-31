#include "ObjectManager.h"
#include "Mem.h"
#include "Offsets.h"
#include "Functions.h"
#include <algorithm>

namespace API::OM {
namespace {

std::mutex g_mu;
std::vector<ObjectInfo> g_objects;
std::vector<ObjectInfo> g_byType[8];

int __cdecl EnumCb(uint64_t guid, void* /*user*/) {
    if (!guid)
        return 1;
    uintptr_t ptr = Functions::ObjectPtr(guid);
    if (!ptr || !Mem::IsPlausiblyReadable(ptr))
        return 1;

    ObjectInfo oi;
    oi.guid = guid;
    oi.ptr = ptr;
    oi.type = Mem::Read<Types::ObjectType>(ptr + Offsets::Object::Type);
    if (oi.type < Types::None || oi.type > Types::Corpse)
        oi.type = Types::None;

    uintptr_t desc = Mem::Read<uintptr_t>(ptr + Offsets::Object::Descriptor);
    if (desc && Mem::IsPlausiblyReadable(desc))
        oi.entry = Mem::Read<int>(desc + Offsets::Descriptor::Entry);

    // Position valid for Unit/Player/GameObject/Corpse typically
    if (oi.type == Types::Unit || oi.type == Types::Player || oi.type == Types::GameObject ||
        oi.type == Types::Corpse || oi.type == Types::DynamicObject) {
        oi.pos = Mem::Read<Vec3>(ptr + Offsets::Object::Position);
        oi.facing = Mem::Read<float>(ptr + Offsets::Object::Facing);
    }

    g_objects.push_back(oi);
    return 1; // continue
}

} // namespace

void Refresh() {
    std::lock_guard<std::mutex> lock(g_mu);
    g_objects.clear();
    for (auto& v : g_byType)
        v.clear();

    // filter -1 = all (classic); some clients use 0
    Functions::EnumVisibleObjects(&EnumCb, -1);

    for (const auto& o : g_objects) {
        int t = static_cast<int>(o.type);
        if (t >= 0 && t < 8)
            g_byType[t].push_back(o);
    }
}

const std::vector<ObjectInfo>& Snapshot() {
    std::lock_guard<std::mutex> lock(g_mu);
    return g_objects;
}

size_t Count() {
    std::lock_guard<std::mutex> lock(g_mu);
    return g_objects.size();
}

const ObjectInfo* GetByIndex(size_t index) {
    std::lock_guard<std::mutex> lock(g_mu);
    if (index == 0 || index > g_objects.size())
        return nullptr;
    return &g_objects[index - 1];
}

const ObjectInfo* GetByGuid(uint64_t guid) {
    std::lock_guard<std::mutex> lock(g_mu);
    for (const auto& o : g_objects) {
        if (o.guid == guid)
            return &o;
    }
    return nullptr;
}

size_t CountByType(Types::ObjectType type) {
    std::lock_guard<std::mutex> lock(g_mu);
    int t = static_cast<int>(type);
    if (t < 0 || t >= 8)
        return 0;
    return g_byType[t].size();
}

const ObjectInfo* GetByTypeIndex(Types::ObjectType type, size_t index) {
    std::lock_guard<std::mutex> lock(g_mu);
    int t = static_cast<int>(type);
    if (t < 0 || t >= 8 || index == 0)
        return nullptr;
    const auto& v = g_byType[t];
    if (index > v.size())
        return nullptr;
    return &v[index - 1];
}

uint64_t LocalPlayerGuid() {
    return Functions::GetActivePlayer();
}

uintptr_t LocalPlayerPtr() {
    uint64_t g = LocalPlayerGuid();
    if (!g)
        return 0;
    return Functions::ObjectPtr(g);
}

} // namespace API::OM
