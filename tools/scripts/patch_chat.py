from pathlib import Path
p = Path(r"C:\Ascension\Workspace\RaijinLab\addon\core\ChatHandler.lua")
text = p.read_text(encoding="utf-8")
if 'cmd == "status"' not in text:
    insert = '''    elseif cmd == "status" then
        local v, b, toc = RaijinLab:ClientBuild()
        SendSystemMessage(string.format("RaijinLab status | runtime=%s | build=%s (%s) toc=%s | ascension=%s",
            tostring(RaijinLab:RuntimeVersion() or "none"),
            tostring(v), tostring(b), tostring(toc),
            tostring(RaijinLab:IsAscensionClient())))
    elseif cmd == "help" then
        SendSystemMessage("RaijinLab: status | mj | aa | fly | nc | tracker | track add/del/all/quest | farm | travel | gps")
'''
    text = text.replace('    elseif cmd == "gps" then', insert + '    elseif cmd == "gps" then')
# wrap RunCommand start with note - optional
if "SLASH_RAIJINLAB1" not in text:
    text += '''

-- Slash commands
SLASH_RAIJINLAB1 = "/rl"
SLASH_RAIJINLAB2 = "/raijin"
SLASH_RAIJINLAB3 = "/raijinlab"
SlashCmdList["RAIJINLAB"] = function(msg)
    RaijinLab:RunCommand(msg or "")
end
'''
p.write_text(text, encoding="utf-8", newline="\n")
print("ChatHandler updated")
