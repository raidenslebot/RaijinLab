// RaijinLab Runtime stub — intentionally non-injecting.
// Purpose: validate x86 build toolchain + export surface for later work.

#include <windows.h>

extern "C" __declspec(dllexport) const char* RaijinLabRuntimeVersion() {
  return "0.0.0-stub";
}

extern "C" __declspec(dllexport) int RaijinLabRuntimePing() {
  return 1;
}

BOOL APIENTRY DllMain(HMODULE hModule, DWORD reason, LPVOID) {
  if (reason == DLL_PROCESS_ATTACH) {
    DisableThreadLibraryCalls(hModule);
  }
  return TRUE;
}
