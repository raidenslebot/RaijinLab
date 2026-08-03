import ctypes, ctypes.wintypes as w

PROCESS_QUERY_INFORMATION = 0x0400
PROCESS_VM_READ = 0x0010
TH32CS_SNAPMODULE = 0x00000008
TH32CS_SNAPMODULE32 = 0x00000010

class MODULEENTRY32W(ctypes.Structure):
    _fields_ = [
        ("dwSize", w.DWORD),
        ("th32ModuleID", w.DWORD),
        ("th32ProcessID", w.DWORD),
        ("GlblcntUsage", w.DWORD),
        ("ProccntUsage", w.DWORD),
        ("modBaseAddr", ctypes.POINTER(ctypes.c_byte)),
        ("modBaseSize", w.DWORD),
        ("hModule", w.HMODULE),
        ("szModule", ctypes.c_wchar * 256),
        ("szExePath", ctypes.c_wchar * 260),
    ]

kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
CreateToolhelp32Snapshot = kernel32.CreateToolhelp32Snapshot
CreateToolhelp32Snapshot.argtypes = [w.DWORD, w.DWORD]
CreateToolhelp32Snapshot.restype = w.HANDLE
Module32FirstW = kernel32.Module32FirstW
Module32FirstW.argtypes = [w.HANDLE, ctypes.POINTER(MODULEENTRY32W)]
Module32FirstW.restype = w.BOOL
Module32NextW = kernel32.Module32NextW
Module32NextW.argtypes = [w.HANDLE, ctypes.POINTER(MODULEENTRY32W)]
Module32NextW.restype = w.BOOL
CloseHandle = kernel32.CloseHandle
CloseHandle.argtypes = [w.HANDLE]

pid = 9336
snap = CreateToolhelp32Snapshot(TH32CS_SNAPMODULE | TH32CS_SNAPMODULE32, pid)
if snap == w.HANDLE(-1).value or not snap:
    print("snapshot failed", ctypes.get_last_error())
    raise SystemExit

me = MODULEENTRY32W()
me.dwSize = ctypes.sizeof(MODULEENTRY32W)
target = 0x6A88F090
print(f"target 0x{target:X}")
if Module32FirstW(snap, ctypes.byref(me)):
    while True:
        base = ctypes.addressof(me.modBaseAddr.contents) if me.modBaseAddr else 0
        size = me.modBaseSize
        end = base + size
        hit = base <= target < end
        mark = "  <<<< HIT" if hit else ""
        if hit or "RaijinLab" in me.szModule or "ascension" in me.szModule.lower():
            off = (target - base) if hit else 0
            print(f"0x{base:08X} +0x{size:08X}  {me.szModule:30s} off=0x{off:X}{mark}")
        if not Module32NextW(snap, ctypes.byref(me)):
            break
CloseHandle(snap)
