#include "API.h"
#include "Mem.h"
#include "Offsets.h"
#include "Functions.h"
#include "Utils.h"

namespace API {

uintptr_t GetObjectPtr(uint64_t guid) {
    if (!guid)
        return 0;
    return Functions::ObjectPtr(guid);
}

Vec3 GetPosition(uint64_t guid) {
    uintptr_t p = GetObjectPtr(guid);
    if (!p)
        return {};
    return Mem::Read<Vec3>(p + Offsets::Object::Position);
}

uintptr_t GetDescriptor(uint64_t guid) {
    uintptr_t p = GetObjectPtr(guid);
    if (!p)
        return 0;
    return Mem::Read<uintptr_t>(p + Offsets::Object::Descriptor);
}

int GetHealth(uint64_t guid) {
    uintptr_t d = GetDescriptor(guid);
    if (!d)
        return 0;
    return Mem::Read<int>(d + Offsets::Descriptor::Health);
}

int GetMaxHealth(uint64_t guid) {
    uintptr_t d = GetDescriptor(guid);
    if (!d)
        return 0;
    return Mem::Read<int>(d + Offsets::Descriptor::MaxHealth);
}

Types::ObjectType GetType(uint64_t guid) {
    uintptr_t p = GetObjectPtr(guid);
    if (!p)
        return Types::None;
    return Mem::Read<Types::ObjectType>(p + Offsets::Object::Type);
}

const char* GetTypeString(uint64_t guid) {
    return Utils::ObjectTypeToString(GetType(guid));
}

int GetID(uint64_t guid) {
    uintptr_t d = GetDescriptor(guid);
    if (!d)
        return 0;
    return Mem::Read<int>(d + Offsets::Descriptor::Entry);
}

int GetLevel(uint64_t guid) {
    uintptr_t d = GetDescriptor(guid);
    if (!d)
        return 0;
    return Mem::Read<int>(d + Offsets::Descriptor::Level);
}

float GetFacing(uint64_t guid) {
    uintptr_t p = GetObjectPtr(guid);
    if (!p)
        return 0.f;
    return Mem::Read<float>(p + Offsets::Object::Facing);
}

bool IsLoggedIn() {
    return GetPlayerGUID() != 0;
}

uint64_t GetPlayerGUID() {
    return Functions::GetActivePlayer();
}

uintptr_t GetPlayerPtr() {
    return GetObjectPtr(GetPlayerGUID());
}

Vec3 GetPlayerPosition() {
    return GetPosition(GetPlayerGUID());
}

void MoveTo(Vec3 position) {
    uintptr_t player = GetPlayerPtr();
    if (!player)
        return;
    uint64_t interact = 0;
    Functions::ClickToMove(player, 4, &interact, &position, 2.0f);
}

Vec3 GetCameraPosition() {
    uintptr_t cam = Functions::GetCamera();
    if (!cam || !Mem::IsPlausiblyReadable(cam))
        return {};
    return Mem::Read<Vec3>(cam + Offsets::Camera::Position);
}

bool TraceLine(const Vec3& start, const Vec3& end, Vec3* hitOut, uint32_t flags) {
    Vec3 s = start, e = end, hit{};
    float dist = 1.0f;
    bool hitSomething = Functions::WorldIntersect(&s, &e, &hit, &dist, flags, 0);
    if (hitOut)
        *hitOut = hit;
    return !hitSomething;
}

std::string GetName(uint64_t guid) {
    (void)guid;
    // VFunc index not locked for Ascension — return empty until live RE.
    return {};
}

void RefreshObjects() {
    OM::Refresh();
}

} // namespace API
