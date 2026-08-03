import subprocess, sys

def rl(code):
    return subprocess.run([sys.executable, r'C:\Ascension\Workspace\RaijinLab\tools\rlctl.py', code],
                          capture_output=True, text=True).stdout.strip()

print('CAM  :', rl('local ok, v = pcall(RaijinLab.GetCameraData, RaijinLab); return tostring(ok).."|"..tostring(v and v.pos and ("pos="..tostring(v.pos)) or tostring(v))'))
print('DIAG :', rl('return tostring(RaijinLab:RuntimeCall("DiagPlayer"))'))
print('PF   :', rl('return tostring(RaijinLab.Actions.PlayerFacing())'))
print('LUA  :', rl('return tostring(GetPlayerFacing())'))
