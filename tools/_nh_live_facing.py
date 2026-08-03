import subprocess, sys

def rl(code):
    return subprocess.run([sys.executable, r'C:\Ascension\Workspace\RaijinLab\tools\rlctl.py', code],
                          capture_output=True, text=True).stdout.strip()

print('PF  :', rl('return tostring(RaijinLab.Actions.PlayerFacing())'))
print('OBJ :', rl('return tostring(RaijinLab.ObjectFacing("player"))'))
print('LUA :', rl('return tostring(GetPlayerFacing())'))
print('POS :', rl('local x,y,z = RaijinLab:ObjectPosition("player"); return tostring(x)..","..tostring(y)..","..tostring(z)'))
