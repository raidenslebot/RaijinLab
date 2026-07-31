#!/usr/bin/env bash
# Run Ghidra headless analysis on a single binary and export decompilation.
# Usage: claude_run_ghidra.sh <binary_path> <project_name>
set -u
BIN="$1"
PROJ="$2"
ROOT="C:/Ascension/Workspace/RaijinLab/tools/bin/ghidra_11.3.2_PUBLIC"
JDK="C:/Ascension/Workspace/RaijinLab/tools/bin/jdk-21.0.11+10"
PROJDIR="C:/Ascension/Workspace/RaijinLab/re/ghidra_proj"
OUTDIR="C:/Ascension/Workspace/RaijinLab/re/ghidra_out"
SCRIPTDIR="C:/Ascension/Workspace/RaijinLab/re/scripts"
mkdir -p "$PROJDIR" "$OUTDIR"
export JAVA_HOME="$JDK"
export PATH="$JDK/bin:$PATH"
"$ROOT/support/analyzeHeadless.bat" "$PROJDIR" "$PROJ" \
  -import "$BIN" \
  -overwrite \
  -scriptPath "$SCRIPTDIR" \
  -postScript claude_ghidra_export.py "$OUTDIR" \
  2>&1
echo "GHIDRA_DONE:$PROJ:$?"
