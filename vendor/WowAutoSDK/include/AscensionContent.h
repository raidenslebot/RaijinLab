/**
 * Ascension SDK - Content Data Reference
 * Auto-generated from Data/Content/*.json
 *
 * Generated: 2026-04-03 10:01:40
 * Files: 18
 *
 * These are the custom Ascension game data files that define
 * spells, items, enchantments, skill cards, etc.
 */

#pragma once

#ifndef ASCENSION_SDK_CONTENT_H
#define ASCENSION_SDK_CONTENT_H


// CharacterAdvancementData.json: Array with 23709 entries
// Fields: AECost, AECost_Random, Class, Expansion, ID, Icon, Name, Quality, Quality_Random, Realms, RequiredLevel, Spells, Tab, Type
// Schema:
//   int AECost;
//   int AECost_Random;
//   const char* Class;
//   int Expansion;
//   int ID;
//   const char* Icon;
//   const char* Name;
//   const char* Quality;
//   const char* Quality_Random;
//   const char* Realms;
//   int RequiredLevel;
//   const char* Spells;
//   const char* Tab;
//   const char* Type;

// EnchantmentToEnchantmentSuggestionData.json: Array with 115920 entries
// Fields: AlsoPick, PeopleWhoPick, RelevancyScore
// Schema:
//   int AlsoPick;
//   int PeopleWhoPick;
//   int RelevancyScore;

// EnchantmentToRoleSuggestionData.json: Array with 1449 entries
// Fields: DamageScore, Enchantment, HealerScore, TankScore
// Schema:
//   int DamageScore;
//   int Enchantment;
//   int HealerScore;
//   int TankScore;

// EnchantmentToStatSuggestionData.json: Array with 1449 entries
// Fields: AgilityScore, Enchantment, IntellectScore, SpiritScore, StrengthScore
// Schema:
//   int AgilityScore;
//   int Enchantment;
//   int IntellectScore;
//   int SpiritScore;
//   int StrengthScore;

// HandOfFateQuestData.json: Array with 8320 entries
// Fields: ID, MinLevel, RequiredItemCount, RequiredItemId, RewardAmount, RewardItem, Specialization
// Schema:
//   int ID;
//   int MinLevel;
//   const char* RequiredItemCount;
//   const char* RequiredItemId;
//   const char* RewardAmount;
//   const char* RewardItem;
//   int Specialization;

// ItemVariationData.json: Array with 10830 entries
// Fields: Bloodforged, Heroic, Mythic, Normal
// Schema:
//   int Bloodforged;
//   int Heroic;
//   const char* Mythic;
//   int Normal;

// LFGData.json: Array with 95 entries
// Fields: DungeonId, FirstQuestAmount1, FirstQuestAmount1TankOrHealer, FirstQuestAmount2, FirstQuestAmount2TankOrHealer, FirstQuestAmount3, FirstQuestAmount3TankOrHealer, FirstQuestId, FirstQuestIdTankOrHealer, FirstQuestItem1, FirstQuestItem1TankOrHealer, FirstQuestItem2, FirstQuestItem2TankOrHealer, FirstQuestItem3, FirstQuestItem3TankOrHealer, FirstQuestMoney, FirstQuestMoneyTankOrHealer, MaxLevel, OtherQuestAmount1, OtherQuestAmount1TankOrHealer
// Schema:
//   int DungeonId;
//   int FirstQuestAmount1;
//   int FirstQuestAmount1TankOrHealer;
//   int FirstQuestAmount2;
//   int FirstQuestAmount2TankOrHealer;
//   int FirstQuestAmount3;
//   int FirstQuestAmount3TankOrHealer;
//   int FirstQuestId;
//   int FirstQuestIdTankOrHealer;
//   int FirstQuestItem1;
//   int FirstQuestItem1TankOrHealer;
//   int FirstQuestItem2;
//   int FirstQuestItem2TankOrHealer;
//   int FirstQuestItem3;
//   int FirstQuestItem3TankOrHealer;
//   int FirstQuestMoney;
//   int FirstQuestMoneyTankOrHealer;
//   int MaxLevel;
//   int OtherQuestAmount1;
//   int OtherQuestAmount1TankOrHealer;

// SkillCardData.json: Array with 49670 entries
// Fields: Entry, IsLucky, Spell
// Schema:
//   int Entry;
//   int IsLucky;
//   int Spell;

// SpellRankData.json: Array with 13311 entries
// Fields: firstSpellId, level, rank, spellId
// Schema:
//   int firstSpellId;
//   int level;
//   int rank;
//   int spellId;

// SpellToEnchantmentSuggestionData.json: Array with 195760 entries
// Fields: AlsoPick, PeopleWhoPick, RelevancyScore
// Schema:
//   int AlsoPick;
//   int PeopleWhoPick;
//   int RelevancyScore;

// SpellToRoleSuggestionData.json: Array with 2447 entries
// Fields: DamageScore, HealerScore, Spell, TankScore
// Schema:
//   int DamageScore;
//   int HealerScore;
//   int Spell;
//   int TankScore;

// SpellToSpellSuggestionData.json: Array with 195760 entries
// Fields: AlsoPick, PeopleWhoPick, RelevancyScore
// Schema:
//   int AlsoPick;
//   int PeopleWhoPick;
//   int RelevancyScore;

// SpellToStatSuggestionData.json: Array with 2447 entries
// Fields: AgilityScore, IntellectScore, Spell, SpiritScore, StrengthScore
// Schema:
//   int AgilityScore;
//   int IntellectScore;
//   int Spell;
//   int SpiritScore;
//   int StrengthScore;

// TradeSkillRecipeData.json: Array with 4136 entries
// Fields: CreatedItemClass, CreatedItemCount, CreatedItemEntry, CreatedItemInventoryType, CreatedItemSubClass, EquippedItemClass, EquippedItemInventoryTypeMask, EquippedItemSubClassMask, IsHighRisk, ReagentData, RecipeItemEntry, RecipeSource, RequiredSkillRank, RequiredSpell, SkillIndex, SpellEntry, SpellFocusObject, TotemCategories, TrivialSkillLineRankHigh, TrivialSkillLineRankLow
// Schema:
//   int CreatedItemClass;
//   int CreatedItemCount;
//   int CreatedItemEntry;
//   int CreatedItemInventoryType;
//   int CreatedItemSubClass;
//   int EquippedItemClass;
//   int EquippedItemInventoryTypeMask;
//   int EquippedItemSubClassMask;
//   int IsHighRisk;
//   const char* ReagentData;
//   int RecipeItemEntry;
//   int RecipeSource;
//   int RequiredSkillRank;
//   int RequiredSpell;
//   int SkillIndex;
//   int SpellEntry;
//   int SpellFocusObject;
//   const char* TotemCategories;
//   int TrivialSkillLineRankHigh;
//   int TrivialSkillLineRankLow;

// TransmogrificationItemData.json: Failed to parse (Expecting value: line 1 column 1 (char 0))

// TransmogrificationItemDisplayData.json: Failed to parse (Expecting value: line 1 column 1 (char 0))

// TransmogrificationItemSetData.json: Failed to parse (Expecting value: line 1 column 1 (char 0))

// WorldMapAreaData.json: Array with 172 entries
// Fields: AreaID, AreaName, ID, LocBottom, LocLeft, LocRight, LocTop, MapID
// Schema:
//   int AreaID;
//   const char* AreaName;
//   int ID;
//   float LocBottom;
//   float LocLeft;
//   float LocRight;
//   float LocTop;
//   int MapID;

// ========================================
// Content data files available:
// ========================================
// Data/Content/CharacterAdvancementData.json
// Data/Content/EnchantmentToEnchantmentSuggestionData.json
// Data/Content/EnchantmentToRoleSuggestionData.json
// Data/Content/EnchantmentToStatSuggestionData.json
// Data/Content/HandOfFateQuestData.json
// Data/Content/ItemVariationData.json
// Data/Content/LFGData.json
// Data/Content/SkillCardData.json
// Data/Content/SpellRankData.json
// Data/Content/SpellToEnchantmentSuggestionData.json
// Data/Content/SpellToRoleSuggestionData.json
// Data/Content/SpellToSpellSuggestionData.json
// Data/Content/SpellToStatSuggestionData.json
// Data/Content/TradeSkillRecipeData.json
// Data/Content/TransmogrificationItemData.json
// Data/Content/TransmogrificationItemDisplayData.json
// Data/Content/TransmogrificationItemSetData.json
// Data/Content/WorldMapAreaData.json

#endif // ASCENSION_SDK_CONTENT_H
