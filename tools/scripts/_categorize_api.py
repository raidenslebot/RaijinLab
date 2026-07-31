"""Generate comprehensive API dispatch table + docs from API_SURFACE.txt"""
from pathlib import Path

apis = Path(r"C:\Ascension\Workspace\RaijinLab\runtime\API_SURFACE.txt").read_text().strip().splitlines()
# categorize
cats = {
  "path": [], "fs": [], "om": [], "geom": [], "unit": [], "world": [], "hack": [], "nav": [], "net": [], "misc": [], "table": []
}
for a in apis:
    if a.startswith(("GetApp","GetWoW","GetSystem","SetSystem","GetCurrentAccount","GetAppUsername")):
        cats["path"].append(a)
    elif a in ("FileExists","ReadFile","WriteFile","DirectoryExists","CreateDirectory","GetDirectoryFiles","GetDirectoryFolders","PlaySoundFile","LoadScript","RunScript","SetCustomScript"):
        cats["fs"].append(a)
    elif "Object" in a or a.startswith(("GetObject","GetNpc","GetPlayer","GetGameObject","GetDynamic","GetArea","GetMissile")):
        cats["om"].append(a)
    elif a.startswith(("GetDistance","GetAngles","GetPosition","ObjectPosition","ObjectFacing","ObjectIs","ObjectId","ObjectExists","ObjectScale","ObjectDescriptor","ObjectField","ObjectType","ObjectDynamic","GameObject")):
        cats["geom"].append(a)
    elif a.startswith("Unit") or a.startswith("GetAura"):
        cats["unit"].append(a)
    elif a in ("TraceLine","WorldToScreen","GetCameraPosition","ClickPosition","FaceDirection","SetPitch","MoveTo","ResetAfk","GetKeyState","StopFalling","CancelPendingSpell","IsAoEPending","SetCameraDistanceMax","SetNameplateDistanceMax","SetCVarEx"):
        cats["world"].append(a)
    elif a.startswith(("EnableFlying","IsFlying","GetNoClip","SetNoClip","SetClimb")):
        cats["hack"].append(a)
    elif "Map" in a or "Mesh" in a or a in ("FindPath","LoadMap","UnloadMap"):
        cats["nav"].append(a)
    elif "Http" in a or "WebSocket" in a or "Websocket" in a or "Packet" in a:
        cats["net"].append(a)
    elif a.endswith("Table") or a.startswith("GetValue") or a.startswith("GetObjectType") or a.startswith("GetUnitMovement") or a.startswith("GetObjectDescriptors") or a.startswith("GetObjectFields") or a.startswith("GetObjectQuest") or a.startswith("GetPacket"):
        cats["table"].append(a)
    else:
        cats["misc"].append(a)

out = Path(r"C:\Ascension\Workspace\RaijinLab\runtime\API_SURFACE_CATEGORIZED.md")
lines = ["# RaijinLab API Surface (124)\n"]
for k,v in cats.items():
    lines.append(f"\n## {k} ({len(v)})\n")
    for a in v:
        lines.append(f"- `{a}`")
out.write_text("\n".join(lines), encoding="utf-8")
print(out)
for k,v in cats.items():
    print(k, len(v))
