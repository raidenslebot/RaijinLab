// Ipc - named-pipe control channel. See Ipc.cpp for the threading contract:
// the pipe thread NEVER touches the client; the addon pumps jobs on the main
// thread via Poll/Reply.
#pragma once

#include <string>

namespace RL {
namespace Ipc {

void Start();
void Stop();

// Main thread only.
std::string Poll(unsigned* id_out);
void Reply(unsigned id, const char* text);

}  // namespace Ipc
}  // namespace RL
