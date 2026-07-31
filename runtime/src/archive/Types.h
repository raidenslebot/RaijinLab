#pragma once
#include <string>
#include <cstdint>
#include <cmath>

struct Vec3 {
    float x = 0, y = 0, z = 0;

    float DistanceTo(const Vec3& o) const {
        const float dx = x - o.x, dy = y - o.y, dz = z - o.z;
        return std::sqrt(dx * dx + dy * dy + dz * dz);
    }

    std::string ToString() const {
        return "(" + std::to_string(x) + ", " + std::to_string(y) + ", " + std::to_string(z) + ")";
    }
};

namespace Types {

enum ObjectType : int {
    None = 0,
    Item,
    Container,
    Unit,
    Player,
    GameObject,
    DynamicObject,
    Corpse
};

enum UnitType : int {
    Unknown = 0,
    Beast,
    Dragonkin,
    Demon,
    Elemental,
    Giant,
    Undead,
    Humanoid,
    Critter,
    Mechanical,
    NotSpecified,
    Totem,
    NonCombatPet,
    GasCloud
};

enum ReactionType : int {
    Hated = 0,
    Hostile,
    Unfriendly,
    Neutral,
    Friendly,
    Honored,
    Revered,
    Exalted
};

} // namespace Types
