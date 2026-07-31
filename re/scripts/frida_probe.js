/**
 * Frida attach-only probe for Ascension.exe (x86).
 * Usage (game running):
 *   frida -n Ascension.exe -l frida_probe.js
 *
 * Research only: module list, exports, MemoryBridge-related strings in maps.
 * Does not patch memory.
 */

function listModules() {
  const mods = Process.enumerateModules();
  console.log("[*] modules:", mods.length);
  mods.forEach(function (m) {
    console.log(
      "  " +
        m.name +
        " base=" +
        m.base +
        " size=" +
        m.size +
        " path=" +
        m.path
    );
  });
  return mods;
}

function findInteresting() {
  const want = [
    "Extensions.dll",
    "DivxTac.dll",
    "DivxDecoder.dll",
    "discord_game_sdk.dll",
    "d3d9.dll",
    "dxgi.dll",
  ];
  want.forEach(function (name) {
    const m = Process.findModuleByName(name);
    if (m) {
      console.log("[+] found " + name + " @ " + m.base);
      try {
        const exps = m.enumerateExports().slice(0, 30);
        exps.forEach(function (e) {
          console.log("    exp " + e.type + " " + e.name + " " + e.address);
        });
      } catch (e) {
        console.log("    export enum failed: " + e);
      }
    } else {
      console.log("[-] missing " + name);
    }
  });
}

function hookCreateProcessOptional() {
  const k32 = Module.findExportByName("kernel32.dll", "CreateProcessW");
  if (!k32) {
    console.log("CreateProcessW not found");
    return;
  }
  Interceptor.attach(k32, {
    onEnter: function (args) {
      try {
        const app = args[0].isNull() ? null : Memory.readUtf16String(args[0]);
        const cmd = args[1].isNull() ? null : Memory.readUtf16String(args[1]);
        if (
          (app && app.toLowerCase().indexOf("mmgr") !== -1) ||
          (cmd && cmd.toLowerCase().indexOf("mmgr") !== -1)
        ) {
          console.log("[CreateProcessW] app=" + app + " cmd=" + cmd);
        }
      } catch (e) {}
    },
  });
  console.log("[*] CreateProcessW probe armed (MMgr filter)");
}

console.log("[RaijinLab] frida probe starting, arch=" + Process.arch);
listModules();
findInteresting();
hookCreateProcessOptional();
console.log("[RaijinLab] probe ready");
