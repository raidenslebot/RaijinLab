#pragma once
#include <cstdarg>
#include <cstdio>

namespace RL::Log {
enum class Level { Trace, Debug, Info, Warn, Error };

void Init(const char* logPath);
void Shutdown();
void SetLevel(Level level);
void Write(Level level, const char* fmt, ...);

inline void Trace(const char* fmt, ...) {
    va_list ap; va_start(ap, fmt);
    char buf[2048]; vsnprintf(buf, sizeof(buf), fmt, ap); va_end(ap);
    Write(Level::Trace, "%s", buf);
}
inline void Debug(const char* fmt, ...) {
    va_list ap; va_start(ap, fmt);
    char buf[2048]; vsnprintf(buf, sizeof(buf), fmt, ap); va_end(ap);
    Write(Level::Debug, "%s", buf);
}
inline void Info(const char* fmt, ...) {
    va_list ap; va_start(ap, fmt);
    char buf[2048]; vsnprintf(buf, sizeof(buf), fmt, ap); va_end(ap);
    Write(Level::Info, "%s", buf);
}
inline void Warn(const char* fmt, ...) {
    va_list ap; va_start(ap, fmt);
    char buf[2048]; vsnprintf(buf, sizeof(buf), fmt, ap); va_end(ap);
    Write(Level::Warn, "%s", buf);
}
inline void Error(const char* fmt, ...) {
    va_list ap; va_start(ap, fmt);
    char buf[2048]; vsnprintf(buf, sizeof(buf), fmt, ap); va_end(ap);
    Write(Level::Error, "%s", buf);
}
} // namespace RL::Log
