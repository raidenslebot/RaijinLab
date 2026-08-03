import ctypes, ctypes.wintypes as w

TH32CS_SNAPMODULE = 0x00000008
TH32CS_SNAPMODULE32 = 0x00000010

class MODULEENTRY32W(ctypes.Structure):
    _fields_ = [
        ("dwSize", w.DWORD), ("th32ModuleID", w.DWORD), ("th32ProcessID", w.DWORD),
        ("GlblcntUsage", w.DWORD), ("ProccntUsage", w.DWORD),
        ("modBaseAddr", ctypes.POINTER(ctypes.c_byte)), ("modBaseSize", w.DWORD),
        ("hModule", w.HMODULE), ("szModule", ctypes.c_wchar * 256),
        ("szExePath", ctypes.c_wchar * 260),
    ]

k32 = ctypes.WinDLL("kernel32", use_last_error=True)
k32.CreateToolhelp32Snapshot.argtypes = [w.DWORD, w.DWORD]
k32.CreateToolhelp32Snapshot.restype = w.HANDLE
k32.Module32FirstW.argtypes = [w.HANDLE, ctypes.POINTER(MODULEENTRY32W)]
k32.Module32FirstW.restype = w.BOOL
k32.Module32NextW.argtypes = [w.HANDLE, ctypes.POINTER(MODULEENTRY32W)]
k32.Module32NextW.restype = w.BOOL
k32.CloseHandle.argtypes = [w.HANDLE]

pid = 9336
snap = k32.CreateToolhelp32Snapshot(TH32CS_SNAPMODULE | TH32CS_SNAPMODULE32, pid)
if not snap:
    print("snapshot failed", ctypes.get_last_error()); raise SystemExit
me = MODULEENTRY32W(); me.dwSize = ctypes.sizeof(MODULEENTRY32W)
found = []
if k32.Module32FirstW(snap, ctypes.byref(me)):
    while True:
        if "RaijinLab" in me.szModule or "ascension" in me.szModule.lower():
            base = ctypes.addressof(me.modBaseAddr.contents) if me.modBaseAddr else 0
            found.append((me.szModule, base, me.modBaseSize, me.szExePath))
        if not k32.Module32NextW(snap, ctypes.byref(me)):
            break
k32.CloseHandle(snap)
for name, base, size, path in found:
    print(f"0x{base:08X} +0x{size:08X}  {name}  -> {path}")
