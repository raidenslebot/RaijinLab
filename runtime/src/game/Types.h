#pragma once
#include <string>
#include <cmath>
#include <cstdint>
#include <cstdio>

namespace RL::Game {

struct Vec3 {
    float x = 0, y = 0, z = 0;
    float Dist(const Vec3& o) const {
        float dx = x - o.x, dy = y - o.y, dz = z - o.z;
        return std::sqrt(dx * dx + dy * dy + dz * dz);
    }
    float Dist2D(const Vec3& o) const {
        float dx = x - o.x, dy = y - o.y;
        return std::sqrt(dx * dx + dy * dy);
    }
    std::string Str() const {
        char b[96];
        snprintf(b, sizeof(b), "(%.3f, %.3f, %.3f)", x, y, z);
        return b;
    }
};

enum class ObjectType : int {
    None = 0, Item, Container, Unit, Player, GameObject, DynamicObject, Corpse
};

inline const char* ObjectTypeName(ObjectType t) {
    static const char* n[] = {"None","Item","Container","Unit","Player","GameObject","DynamicObject","Corpse"};
    int i = (int)t;
    return (i >= 0 && i < 8) ? n[i] : "Invalid";
}

} // namespace RL::Game
