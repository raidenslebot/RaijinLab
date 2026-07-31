# Ascension AddOns (extracted from patch-B.MPQ)

**Source:** `Data/patch-B.MPQ`  
**Extract path:** `re/mpq_extract/ascension_addons/`  
**Count:** 566 files, 1299 listfile entries in archive  
**TOC Interface:** **30300** (all custom addons)

## Notable packages

| Addon | Role |
|-------|------|
| AscensionUI | Main UI shell |
| Ascension_CharacterAdvancement | Classless / CA system |
| Ascension_SkillCards | Skill cards |
| Ascension_Collections | Collections hub |
| Ascension_NamePlates | Custom nameplates |
| Ascension_MythicPlus | M+ keystones |
| Ascension_Manastorm | Manastorm mode |
| Ascension_BuildCreator | Hero architect |
| Ascension_WildCard / Wildcard | Wildcard gamemode |
| Ascension_Draft | Draft UI |
| Ascension_InspectUI | Custom inspect |
| Ascension_UIDevelopmentTools | `/devconsole` (disabled by default) |
| Postal | Mail enhancement |
| BagSearch / BagSort | QoL |

## Implication for RaijinLab

- Disk addon install at `Interface/AddOns/RaijinLab` is the correct pattern (same as loose override of MPQ).
- Interface version **30300** confirmed by both FrameXML and every Ascension addon TOC.
- Custom natives used by these UIs live in **Extensions.dll** — study extracted Lua for call sites (`notes/08_extracted_addon_apis.txt`).
