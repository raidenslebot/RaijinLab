import subprocess, sys

def rl(code):
    return subprocess.run([sys.executable, r'C:\Ascension\Workspace\RaijinLab\tools\rlctl.py', code],
                          capture_output=True, text=True).stdout.strip()

# Correct calling conventions: colon calls
print('PF-A :', rl('local a = RaijinLab and RaijinLab.Actions; return a and tostring(a.PlayerFacing())'))
print('PF-B :', rl('return tostring(RaijinLab:RuntimeCall("PlayerFacing"))'))
print('OFAC :', rl('local ok, v = pcall(RaijinLab.ObjectFacing, RaijinLab, "player"); return tostring(ok).."|"..tostring(v)'))
print('LUA  :', rl('return tostring(GetPlayerFacing())'))
print('TGT  :', rl('return tostring(UnitGUID and UnitGUID("target"))'))
print('POS  :', rl('local x,y,z = RaijinLab:ObjectPosition("player"); return tostring(x)..","..tostring(y)..","..tostring(z)'))
print('CAM  :', rl('local ok, v = pcall(RaijinLab.GetCameraData, RaijinLab); return tostring(ok).."|"..tostring(v)'))
