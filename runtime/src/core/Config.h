#pragma once
#include <string>
#include <unordered_map>
#include <mutex>

namespace RL::Config {

// Persistent key/value store (maps GetSystemVar / SetSystemVar)
void Init(const char* path);
void Shutdown();
std::string Get(const std::string& key, const std::string& def = {});
void Set(const std::string& key, const std::string& value);
void Flush();

struct Options {
    bool console = true;
    bool autoRegisterLua = true;
    int registerRetryMs = 1000;
    int omCacheMs = 200;         // object manager snapshot TTL (Manager polls every frame)
    bool logApiCalls = false;
    bool enableHacks = false;    // flying/noclip gated
};
Options& Opts();

} // namespace RL::Config
