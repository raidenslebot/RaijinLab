#include "Config.h"
#include "Log.h"
#include <Windows.h>
#include <fstream>
#include <sstream>

namespace RL::Config {
namespace {
std::mutex g_mu;
std::unordered_map<std::string, std::string> g_kv;
std::string g_path;
Options g_opts;

void LoadUnlocked() {
    g_kv.clear();
    std::ifstream in(g_path);
    if (!in) return;
    std::string line;
    while (std::getline(in, line)) {
        if (line.empty() || line[0] == '#') continue;
        auto eq = line.find('=');
        if (eq == std::string::npos) continue;
        g_kv[line.substr(0, eq)] = line.substr(eq + 1);
    }
}
}

void Init(const char* path) {
    std::lock_guard<std::mutex> lock(g_mu);
    g_path = path ? path : "";
    CreateDirectoryA("C:\\Ascension\\Workspace\\logs", nullptr);
    LoadUnlocked();
    auto it = g_kv.find("log.api");
    if (it != g_kv.end()) g_opts.logApiCalls = (it->second == "1" || it->second == "true");
    it = g_kv.find("hacks.enable");
    if (it != g_kv.end()) g_opts.enableHacks = (it->second == "1" || it->second == "true");
    RL::Log::Info("config loaded entries=%zu path=%s", g_kv.size(), g_path.c_str());
}

void Shutdown() { Flush(); }

std::string Get(const std::string& key, const std::string& def) {
    std::lock_guard<std::mutex> lock(g_mu);
    auto it = g_kv.find(key);
    return it == g_kv.end() ? def : it->second;
}

void Set(const std::string& key, const std::string& value) {
    std::lock_guard<std::mutex> lock(g_mu);
    g_kv[key] = value;
}

void Flush() {
    std::lock_guard<std::mutex> lock(g_mu);
    if (g_path.empty()) return;
    std::ofstream out(g_path, std::ios::trunc);
    out << "# RaijinLab system vars\n";
    for (auto& kv : g_kv) out << kv.first << "=" << kv.second << "\n";
}

Options& Opts() { return g_opts; }

} // namespace RL::Config
