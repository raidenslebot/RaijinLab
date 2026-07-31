// Ipc - a named pipe into the live client, so the client can be driven from
// outside without a human retyping slash commands.
//
// WHY. Every diagnosis in this project has been a round trip: ask for a command,
// wait for a screenshot, read numbers off it, guess again. That is slow and it
// loses information - a screenshot cannot be grepped, and "nothing renders" has
// six causes that look identical from the outside.
//
// THREAD SAFETY IS THE WHOLE DESIGN. The client is emphatically single-threaded:
// touching its Lua state or object manager from a background thread is how you
// get an access violation on world load. So this DLL never calls the client at
// all. The pipe thread does exactly one thing - move a string into a queue - and
// the ADDON, which is already ticking on the main thread every frame, pulls it
// out, runs it, and hands back the result. The only shared state is a mutex and
// two std::deques.
//
// The pipe is local-only (no network), one connection at a time, and exists only
// while the DLL is loaded.

#include "Ipc.h"

#include <windows.h>

#include <deque>
#include <mutex>
#include <string>
#include <thread>

#include "../core/Log.h"

namespace RL {
namespace Ipc {
namespace {

struct Job {
    unsigned id = 0;
    std::string code;
    std::string reply;
    bool done = false;
};

std::mutex g_m;
std::deque<Job*> g_pending;     // waiting for the main thread to run them
std::deque<Job*> g_inflight;    // running; waiting for a reply
unsigned g_next_id = 1;
volatile bool g_run = false;
HANDLE g_thread = nullptr;

const wchar_t* kPipe = L"\\\\.\\pipe\\RaijinLab";
const DWORD kJobTimeoutMs = 10000;   // a wedged main thread must not hang us

bool ReadExact(HANDLE h, void* buf, DWORD n) {
    DWORD got = 0, total = 0;
    while (total < n) {
        if (!ReadFile(h, (char*)buf + total, n - total, &got, nullptr) || got == 0)
            return false;
        total += got;
    }
    return true;
}

bool WriteExact(HANDLE h, const void* buf, DWORD n) {
    DWORD put = 0, total = 0;
    while (total < n) {
        if (!WriteFile(h, (const char*)buf + total, n - total, &put, nullptr) || put == 0)
            return false;
        total += put;
    }
    return true;
}

// One request per connection: [u32 len][payload] in, [u32 len][payload] out.
// Length-prefixed rather than line-based because the payload is Lua and will
// contain newlines.
void ServeOne(HANDLE pipe) {
    unsigned len = 0;
    if (!ReadExact(pipe, &len, 4)) return;
    if (len == 0 || len > (1u << 20)) return;          // 1MB ceiling
    std::string code(len, '\0');
    if (!ReadExact(pipe, &code[0], len)) return;

    Job* job = new Job();
    {
        std::lock_guard<std::mutex> lk(g_m);
        job->id = g_next_id++;
        job->code = code;
        g_pending.push_back(job);
    }

    // Wait for the main thread to run it. Polling a flag under the mutex is
    // enough here: jobs complete in a frame or two, and a condition variable
    // would add a second synchronisation object for no benefit.
    DWORD waited = 0;
    std::string reply;
    bool ok = false;
    while (waited < kJobTimeoutMs) {
        {
            std::lock_guard<std::mutex> lk(g_m);
            if (job->done) { reply = job->reply; ok = true; break; }
        }
        Sleep(5);
        waited += 5;
    }
    if (!ok) {
        // Drop it from the queues so a timed-out job cannot be run later against
        // a caller that has gone away.
        std::lock_guard<std::mutex> lk(g_m);
        for (auto it = g_pending.begin(); it != g_pending.end(); ++it)
            if (*it == job) { g_pending.erase(it); break; }
        for (auto it = g_inflight.begin(); it != g_inflight.end(); ++it)
            if (*it == job) { g_inflight.erase(it); break; }
        reply = "ERROR: timed out waiting for the game's main thread (is the "
                "client running, in world, and is the addon loaded?)";
    }
    delete job;

    unsigned rlen = (unsigned)reply.size();
    WriteExact(pipe, &rlen, 4);
    if (rlen) WriteExact(pipe, reply.data(), rlen);
    FlushFileBuffers(pipe);
}

DWORD WINAPI ServerThread(LPVOID) {
    while (g_run) {
        HANDLE pipe = CreateNamedPipeW(
            kPipe, PIPE_ACCESS_DUPLEX,
            PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT,
            1, 64 * 1024, 64 * 1024, 0, nullptr);
        if (pipe == INVALID_HANDLE_VALUE) { Sleep(250); continue; }
        BOOL connected = ConnectNamedPipe(pipe, nullptr)
            ? TRUE : (GetLastError() == ERROR_PIPE_CONNECTED);
        if (connected && g_run) ServeOne(pipe);
        DisconnectNamedPipe(pipe);
        CloseHandle(pipe);
    }
    return 0;
}

}  // namespace

void Start() {
    if (g_run) return;
    g_run = true;
    g_thread = CreateThread(nullptr, 0, ServerThread, nullptr, 0, nullptr);
    RL::Log::Info("Ipc: named pipe \\\\.\\pipe\\RaijinLab open");
}

void Stop() {
    if (!g_run) return;
    g_run = false;
    // Unblock ConnectNamedPipe by connecting to ourselves once.
    HANDLE h = CreateFileW(kPipe, GENERIC_READ | GENERIC_WRITE, 0, nullptr,
                           OPEN_EXISTING, 0, nullptr);
    if (h != INVALID_HANDLE_VALUE) CloseHandle(h);
    if (g_thread) {
        WaitForSingleObject(g_thread, 1000);
        CloseHandle(g_thread);
        g_thread = nullptr;
    }
}

// MAIN THREAD ONLY. Returns the next queued job's code, or an empty string.
std::string Poll(unsigned* id_out) {
    std::lock_guard<std::mutex> lk(g_m);
    if (g_pending.empty()) { if (id_out) *id_out = 0; return std::string(); }
    Job* j = g_pending.front();
    g_pending.pop_front();
    g_inflight.push_back(j);
    if (id_out) *id_out = j->id;
    return j->code;
}

// MAIN THREAD ONLY. Hands the result back to whoever is waiting on the pipe.
void Reply(unsigned id, const char* text) {
    std::lock_guard<std::mutex> lk(g_m);
    for (auto it = g_inflight.begin(); it != g_inflight.end(); ++it) {
        if ((*it)->id == id) {
            (*it)->reply = text ? text : "";
            (*it)->done = true;
            g_inflight.erase(it);
            return;
        }
    }
}

}  // namespace Ipc
}  // namespace RL
