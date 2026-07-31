#pragma once
#include <cstdint>
#include <string>
#include "Types.h"
#include "ObjectManager.h"

namespace API {

uintptr_t GetObjectPtr(uint64_t guid);
Vec3 GetPosition(uint64_t guid);
uintptr_t GetDescriptor(uint64_t guid);
int GetHealth(uint64_t guid);
int GetMaxHealth(uint64_t guid);
Types::ObjectType GetType(uint64_t guid);
const char* GetTypeString(uint64_t guid);
int GetID(uint64_t guid);
int GetLevel(uint64_t guid);
float GetFacing(uint64_t guid);

bool IsLoggedIn();
uint64_t GetPlayerGUID();
uintptr_t GetPlayerPtr();
Vec3 GetPlayerPosition();
void MoveTo(Vec3 position);
Vec3 GetCameraPosition();

// World LOS (TraceLine-style). Returns true if clear / based on intersect result.
bool TraceLine(const Vec3& start, const Vec3& end, Vec3* hitOut, uint32_t flags);

// VTable helper (object name often vfunc)
template <std::size_t Index, typename Ret, typename... Args>
Ret CallVFunc(uintptr_t objectPtr, Args... args) {
    using Fn = Ret(__thiscall*)(void*, Args...);
    auto** vtable = *reinterpret_cast<Fn***>(objectPtr);
    return vtable[Index](reinterpret_cast<void*>(objectPtr), args...);
}

// CGObject name — vfunc index may differ; try common 3.3.5 index 54/28 carefully.
std::string GetName(uint64_t guid);

void RefreshObjects();

} // namespace API
