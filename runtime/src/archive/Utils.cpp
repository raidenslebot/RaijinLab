#include "Utils.h"

namespace Utils {

static const char* kObjectTypes[] = {
    "None", "Item", "Container", "Unit", "Player", "GameObject", "DynamicObject", "Corpse"};

static const char* kUnitTypes[] = {
    "Unknown", "Beast", "Dragonkin", "Demon", "Elemental", "Giant", "Undead",
    "Humanoid", "Critter", "Mechanical", "NotSpecified", "Totem", "NonCombatPet", "GasCloud"};

static const char* kReactions[] = {
    "Hated", "Hostile", "Unfriendly", "Neutral", "Friendly", "Honored", "Revered", "Exalted"};

const char* ObjectTypeToString(Types::ObjectType type) {
    const int i = static_cast<int>(type);
    if (i < 0 || i >= 8)
        return "Invalid";
    return kObjectTypes[i];
}

const char* UnitTypeToString(Types::UnitType type) {
    const int i = static_cast<int>(type);
    if (i < 0 || i >= 14)
        return "Invalid";
    return kUnitTypes[i];
}

const char* ReactionTypeToString(Types::ReactionType type) {
    const int i = static_cast<int>(type);
    if (i < 0 || i >= 8)
        return "Invalid";
    return kReactions[i];
}

} // namespace Utils
