#pragma once
#include <cstdarg>
#include <cstdio>
#include <cstring>
#include <Windows.h>

namespace RL::Log {

// ---- Level ---------------------------------------------------------------
enum class Level { Trace = 0, Debug = 1, Info = 2, Warn = 3, Error = 4 };

// ---- Structured log entry ------------------------------------------------
// Format: HH:MM:SS.mmm|L|cat.sub|k1=v1 k2=v2 ...
//   L = single-char level: T=Trace D=Debug I=Info W=Warn E=Error
//   cat.sub = hierarchical category (e.g. br.reg, om.walk, cast.fire)
//   Body = key=value pairs, space-separated, machine-parseable
//
// Usage via macros (auto-captures file/line):
//   LOG_I("br.reg", "ver=%s L=%p bits=0x%X", ver, L, bits)
//   LOG_W("om.freeze", "durMs=%llu reason=%s", dur, reason)
//   LOG_E("cast.crash", "spellId=%d err=0x%X", sid, code)

void Init(const char* logPath);
void Shutdown();
void SetLevel(Level level);
Level GetLevel();

// Core structured write. `cat_sub` is "cat.sub" hierarchical key.
void Structured(Level level, const char* file, int line,
                const char* cat_sub, const char* fmt, ...);

// Backward-compat legacy free-form write (still goes through same sink).
void Write(Level level, const char* fmt, ...);

// ---- Convenience macros (capture file+line) ------------------------------
#define LOG_T(cat_sub, fmt, ...) \
    RL::Log::Structured(RL::Log::Level::Trace, __FILE__, __LINE__, cat_sub, fmt, ##__VA_ARGS__)
#define LOG_D(cat_sub, fmt, ...) \
    RL::Log::Structured(RL::Log::Level::Debug, __FILE__, __LINE__, cat_sub, fmt, ##__VA_ARGS__)
#define LOG_I(cat_sub, fmt, ...) \
    RL::Log::Structured(RL::Log::Level::Info, __FILE__, __LINE__, cat_sub, fmt, ##__VA_ARGS__)
#define LOG_W(cat_sub, fmt, ...) \
    RL::Log::Structured(RL::Log::Level::Warn, __FILE__, __LINE__, cat_sub, fmt, ##__VA_ARGS__)
#define LOG_E(cat_sub, fmt, ...) \
    RL::Log::Structured(RL::Log::Level::Error, __FILE__, __LINE__, cat_sub, fmt, ##__VA_ARGS__)

// ---- Legacy free-form wrappers (keep old callers working) ----------------
inline void Trace(const char* fmt, ...) {
    va_list ap; va_start(ap, fmt); char buf[2048];
    vsnprintf(buf, sizeof(buf), fmt, ap); va_end(ap);
    Write(Level::Trace, "%s", buf);
}
inline void Debug(const char* fmt, ...) {
    va_list ap; va_start(ap, fmt); char buf[2048];
    vsnprintf(buf, sizeof(buf), fmt, ap); va_end(ap);
    Write(Level::Debug, "%s", buf);
}
inline void Info(const char* fmt, ...) {
    va_list ap; va_start(ap, fmt); char buf[2048];
    vsnprintf(buf, sizeof(buf), fmt, ap); va_end(ap);
    Write(Level::Info, "%s", buf);
}
inline void Warn(const char* fmt, ...) {
    va_list ap; va_start(ap, fmt); char buf[2048];
    vsnprintf(buf, sizeof(buf), fmt, ap); va_end(ap);
    Write(Level::Warn, "%s", buf);
}
inline void Error(const char* fmt, ...) {
    va_list ap; va_start(ap, fmt); char buf[2048];
    vsnprintf(buf, sizeof(buf), fmt, ap); va_end(ap);
    Write(Level::Error, "%s", buf);
}

} // namespace RL::Log
