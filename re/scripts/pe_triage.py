import pefile, os, hashlib, json
from pathlib import Path

dump = Path(r"C:\Ascension\Workspace\RaijinLab\re\dumps")
results = []
for p in sorted(dump.glob("*")):
    if not p.is_file():
        continue
    data = p.read_bytes()
    sha = hashlib.sha256(data).hexdigest()
    info = {
        "name": p.name,
        "size": len(data),
        "sha256": sha,
        "mz": data[:2] == b"MZ",
    }
    try:
        pe = pefile.PE(data=data, fast_load=True)
        pe.parse_data_directories(directories=[
            pefile.DIRECTORY_ENTRY['IMAGE_DIRECTORY_ENTRY_IMPORT'],
            pefile.DIRECTORY_ENTRY['IMAGE_DIRECTORY_ENTRY_EXPORT'],
            pefile.DIRECTORY_ENTRY['IMAGE_DIRECTORY_ENTRY_RESOURCE'],
        ])
        info["machine"] = hex(pe.FILE_HEADER.Machine)
        info["arch"] = {0x14c:"x86",0x8664:"x64"}.get(pe.FILE_HEADER.Machine, "other")
        info["timestamp"] = pe.FILE_HEADER.TimeDateStamp
        info["characteristics"] = hex(pe.FILE_HEADER.Characteristics)
        info["subsystem"] = pe.OPTIONAL_HEADER.Subsystem
        info["image_base"] = hex(pe.OPTIONAL_HEADER.ImageBase)
        info["entry_point"] = hex(pe.OPTIONAL_HEADER.AddressOfEntryPoint)
        info["sections"] = [(s.Name.decode(errors='replace').rstrip('\x00'), hex(s.VirtualAddress), s.Misc_VirtualSize, s.SizeOfRawData, hex(s.Characteristics)) for s in pe.sections]
        if hasattr(pe, 'DIRECTORY_ENTRY_IMPORT'):
            info["imports"] = {e.dll.decode(errors='replace'): [i.name.decode(errors='replace') if i.name else f"ord_{i.ordinal}" for i in e.imports[:40]] for e in pe.DIRECTORY_ENTRY_IMPORT}
        if hasattr(pe, 'DIRECTORY_ENTRY_EXPORT'):
            info["exports"] = [e.name.decode(errors='replace') if e.name else f"ord_{e.ordinal}" for e in pe.DIRECTORY_ENTRY_EXPORT.symbols[:80]]
            info["export_count"] = len(pe.DIRECTORY_ENTRY_EXPORT.symbols)
        # packer / anomaly hints
        entropy = []
        for s in pe.sections:
            raw = s.get_data()
            if not raw:
                entropy.append((s.Name.decode(errors='replace').rstrip('\x00'), 0.0))
                continue
            from collections import Counter
            import math
            c = Counter(raw)
            n = len(raw)
            ent = -sum((v/n)*math.log2(v/n) for v in c.values())
            entropy.append((s.Name.decode(errors='replace').rstrip('\x00'), round(ent, 3)))
        info["section_entropy"] = entropy
        pe.close()
    except Exception as e:
        info["pe_error"] = str(e)
    results.append(info)
    print("="*60)
    print(info["name"], info["size"], "sha256", sha[:16]+"...")
    print(" arch:", info.get("arch"), "EP:", info.get("entry_point"), "base:", info.get("image_base"))
    if "sections" in info:
        print(" sections:")
        for s in info["sections"]:
            print("  ", s)
    if "section_entropy" in info:
        print(" entropy:", info["section_entropy"])
    if "exports" in info:
        print(" exports(%d):" % info.get("export_count",0), info["exports"][:30])
    if "imports" in info:
        print(" import DLLs:", list(info["imports"].keys()))
    if "pe_error" in info:
        print(" PE ERROR:", info["pe_error"])

outp = Path(r"C:\Ascension\Workspace\RaijinLab\re\pe_triage.json")
outp.write_text(json.dumps(results, indent=2), encoding="utf-8")
print("\nWrote", outp)
