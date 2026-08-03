import subprocess, sys

def rl(code):
    return subprocess.run([sys.executable, r'C:\Ascension\Workspace\RaijinLab\tools\rlctl.py', code],
                          capture_output=True, text=True).stdout.strip()

print('VER  :', rl('return tostring(RaijinLab:RuntimeCall("GetRuntimeVersion"))'))
print('PF   :', rl('return tostring(RaijinLab.Actions.PlayerFacing())'))
print('LUA  :', rl('return tostring(GetPlayerFacing())'))
print('TGT  :', rl('return tostring(UnitGUID and UnitGUID("target"))'))
print('VEREXPECTED: 1.10.83-castguid')
