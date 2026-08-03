import subprocess, sys

def rl(code):
    return subprocess.run([sys.executable, r'C:\Ascension\Workspace\RaijinLab\tools\rlctl.py', code],
                          capture_output=True, text=True).stdout.strip()

print('DIAG :', rl('return tostring(RaijinLab:RuntimeCall("DiagPlayer"))'))
print('PF   :', rl('return tostring(RaijinLab.Actions.PlayerFacing())'))
print('LUA  :', rl('return tostring(GetPlayerFacing())'))
# Check what ReadMemory stubs - it returns nil. Try PosProbe which logs position layout
print('POSPROBE:', rl('return tostring(RaijinLab:RuntimeCall("PosProbe"))'))
