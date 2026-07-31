from pathlib import Path
api = Path(r"C:\Ascension\Workspace\RaijinLab\addon\core\API.lua")
text = api.read_text(encoding="utf-8")
# Insert bridge after first block of cache init
bridge = '''
-- Runtime bridge (RaijinLab_Runtime preferred, IsLinuxClient legacy)
local function RLCall(...)
    if type(RaijinLab_Runtime) == "function" then
        return RaijinLab_Runtime(...)
    end
    if type(IsLinuxClient) == "function" then
        return IsLinuxClient(...)
    end
    return nil
end

'''
if "local function RLCall" not in text:
    # after enums line or after pack helpers
    marker = "cxmplex.enums = {}"  # already rebranded
    marker = "RaijinLab.enums = {}"
    if marker in text:
        text = text.replace(marker, marker + "\n" + bridge, 1)
    else:
        text = bridge + text
text = text.replace("IsLinuxClient(", "RLCall(")
api.write_text(text, encoding="utf-8", newline="\n")
print("API.lua RLCall count", text.count("RLCall("))
print("remaining IsLinuxClient", text.count("IsLinuxClient"))
