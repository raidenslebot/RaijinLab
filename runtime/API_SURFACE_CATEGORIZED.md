# RaijinLab API Surface (124)


## path (7)

- `GetAppDirectory`
- `GetAppStorageDirectory`
- `GetAppUsername`
- `GetCurrentAccount`
- `GetSystemVar`
- `GetWoWDirectory`
- `SetSystemVar`

## fs (11)

- `CreateDirectory`
- `DirectoryExists`
- `FileExists`
- `GetDirectoryFiles`
- `GetDirectoryFolders`
- `LoadScript`
- `PlaySoundFile`
- `ReadFile`
- `RunScript`
- `SetCustomScript`
- `WriteFile`

## om (38)

- `GameObjectType`
- `GetAnglesBetweenObjects`
- `GetAreaTriggerCount`
- `GetAreaTriggerWithIndex`
- `GetDistanceBetweenObjects`
- `GetDynamicObjectCount`
- `GetDynamicObjectWithIndex`
- `GetGameObjectCount`
- `GetGameObjectWithIndex`
- `GetMissileCount`
- `GetMissileWithIndex`
- `GetNpcCount`
- `GetNpcWithIndex`
- `GetObject`
- `GetObjectCount`
- `GetObjectDescriptorsTable`
- `GetObjectFieldsTable`
- `GetObjectQuestGiverStatusesTable`
- `GetObjectTypeFlagsTable`
- `GetObjectWithGUID`
- `GetObjectWithIndex`
- `GetPlayerCount`
- `GetPlayerWithIndex`
- `GetPositionBetweenObjects`
- `ObjectDescriptor`
- `ObjectDynamicFlags`
- `ObjectExists`
- `ObjectFacing`
- `ObjectField`
- `ObjectId`
- `ObjectIsBehind`
- `ObjectIsFacing`
- `ObjectIsQuestObjective`
- `ObjectIsType`
- `ObjectPosition`
- `ObjectQuestGiverStatus`
- `ObjectScale`
- `ObjectTypeFlags`

## geom (3)

- `GetDistanceBetweenPositions`
- `GetPositionBetweenPositions`
- `GetPositionFromPosition`

## unit (19)

- `GetAuraCount`
- `GetAuraWithIndex`
- `UnitBoundingRadius`
- `UnitCasting`
- `UnitCastingTarget`
- `UnitChannel`
- `UnitCombatReach`
- `UnitCreator`
- `UnitCreatureFamilyId`
- `UnitCreatureField`
- `UnitCreatureTypeId`
- `UnitFlags`
- `UnitIsLootable`
- `UnitIsMounted`
- `UnitIsSkinnable`
- `UnitMovementFlags`
- `UnitPitch`
- `UnitTarget`
- `UnitTransport`

## world (15)

- `CancelPendingSpell`
- `ClickPosition`
- `FaceDirection`
- `GetCameraPosition`
- `GetKeyState`
- `IsAoEPending`
- `MoveTo`
- `ResetAfk`
- `SetCVarEx`
- `SetCameraDistanceMax`
- `SetNameplateDistanceMax`
- `SetPitch`
- `StopFalling`
- `TraceLine`
- `WorldToScreen`

## hack (5)

- `EnableFlyingMode`
- `GetNoClipModes`
- `IsFlyingModeEnabled`
- `SetClimbAngle`
- `SetNoClipModes`

## nav (13)

- `FindPath`
- `GetClosestMeshPolygon`
- `GetClosestPositionOnMesh`
- `GetCurrentMapInfo`
- `GetMeshPolygonFlags`
- `GetMeshPolygonVertices`
- `GetMeshPolygons`
- `GetMeshTile`
- `IsMapLoaded`
- `LoadMap`
- `MapExists`
- `SetMeshPolygonFlags`
- `UnloadMap`

## net (8)

- `CloseWebSocket`
- `ConnectWebsocket`
- `EnablePacketLogger`
- `GetPacketOpcodes`
- `IsPacketLoggerEnabled`
- `ReceiveHttpRequest`
- `SendHttpRequest`
- `SendWebsocketData`

## misc (3)

- `GetAllSpanningCircles`
- `GetMemoryOffset`
- `ReadMemory`

## table (2)

- `GetUnitMovementFlagsTable`
- `GetValueTypesTable`