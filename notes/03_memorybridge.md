# MemoryBridge Protocol — Static Map

## Roles
- **Server:** `MMgr64.exe` (x64) — launched by Extensions with client PID + object token
- **Client:** `Extensions.dll` inside Ascension.exe (x86)
- **Protocol version:** 3 (runtime log)

## Launch contract (from strings)
Extensions:
- `MMgr64.exe not found at: {}`
- `MMgr64.exe server process.`
- `MMgr64.exe without a valid object token.`
- `CreateProcessW` / `CreateProcess failed with error code: {}`

MMgr64:
- Requires **client PID** + **object token**
- Validates session ID match (rejects cross-session PID)
- Exits if client PID not running / terminated
- Security descriptor on mapping object
- Rejects malformed object token

## Operations observed (first run log)
1. Init server+client with protocol=3
2. Alloc 1024 bytes handle 1 → write → read → free (self-test)
3. command 3 → invalid_argument (benign test edge)
4. Create table handles 1..6 with fixed record sizes
5. Shutdown on client exit

## Table sizes (session)
| handle | records | record size | approx bytes |
|--------|---------|-------------|--------------|
| 1 | 6801 | 12 | 80 KB |
| 2 | 36548 | 12 | 428 KB |
| 3 | 127121 | 28 | 3.4 MB |
| 4 | 18561 | 116 | 2.1 MB |
| 5 | 562792 | 64 | 34.4 MB |
| 6 | 10667 | 180 | 1.9 MB |

Record counts resemble DBC/content table cardinalities — treat as **content/integrity mirrors** until proven otherwise.

## Format strings (server)
```
Invalid client PID {}; exiting server.
Client process (PID {}) not found; exiting server.
Client process (PID {}) is not running; exiting server.
Unable to validate client process session for PID {}; exiting server.
Client process (PID {}) is in session {}, server is in session {}; exiting server.
Monitoring client process with PID {}.
Client process (PID {}) terminated. Shutting down server.
Unknown command {}
Allocated {} bytes, handle {}
Allocation failed for {} bytes
Freed memory for handle {}
Invalid handle {} for free
Read out of bounds for handle {}
Read {} bytes from handle {}
Write out of bounds for handle {}
Wrote {} bytes to handle {}
Unknown batch operation {}
Table allocation failed for {} records of {} bytes
Created table handle {} with {} records of {} bytes
Invalid table handle {} for destroy
Record write failed for table {}
Record patch failed for table {}
Record read failed for table {}
String write failed for table {}
String read failed for table {}
UInt32 index build failed for table {}
UInt32 index lookup failed for table {}
CString read failed for table {}
UInt32 indexed record read failed for table {}
CString batch read failed for table {}
Indexed record batch read failed for table {}
Projected record read failed for table {}
Projected record batch read failed for table {}
Projected predicate query failed for table {}
{} rejected invalid client PID {}.
{} failed to open client PID {}: {}
{} rejected non-running client PID {}: wait result {}
{} failed to validate client session for PID {}: {}
{} rejected client PID {} from session {}; server session is {}.
Refusing to use existing MemoryBridge {}.
Failed to create MemoryBridge object security descriptor: {}
Failed to create request mapping: {}
Failed to map request view: {}
Failed to create response mapping: {}
Failed to map response view: {}
Failed to create request event: {}
Failed to create response event: {}
MemoryBridgeServer initialized. clientPID={} serverPID={} protocol={}
Response message too large to send: {} bytes
Failed to signal response event: {}
[{}] {}
```

## Format strings (client MB)
```
Failed to generate a valid MemoryBridge object token.
Failed to launch MMgr64.exe server process.
MemoryBridgeClient initialized. clientPID={} serverPID={} protocol={}
MemoryBridge shutdown request failed: {}
MemoryBridge shutdown request skipped: {}
MemoryBridge shutdown request skipped: unknown error
MemoryBridgeClient shutdown.
Refusing to launch MMgr64.exe without a valid object token.
MMgr64.exe not found at: {}
CreateProcess failed with error code: {}
MemoryBridge handshake rejected: {}
MemoryBridge handshake PID mismatch. client expected={} actual={} server={}
MemoryBridge handshake failed: {}
MemoryBridge handshake failed: unknown error
MemoryBridgeClient is {}.
MemoryBridgeClient is not connected.
Timed out waiting {} ms for MemoryBridge command {}.
MemoryBridge protocol mismatch. client={} server={}
MemoryBridge command {} returned {}. clientPID={} serverPID={}
MemoryBridge server exited before {} opened. Last error: {}
MemoryBridge.log
MemoryBridge communication test passed.
CreateProcessW
```

## Security implications for RaijinLab Runtime
1. MMgr64 is a **trusted co-process** with OpenProcess on the game — AC may assume exclusive external access patterns.
2. Shared memory name/token is **session-bound**; spoofing without matching token fails.
3. Killing MMgr may crash or trip Extensions handshake paths.
4. Protocol mismatch is explicit hard-fail.

## Next dynamic RE
- Capture command line of MMgr64 at spawn
- Enumerate named file mappings while in-world
- Dump table headers for schema
- Frida/x32dbg on Extensions CreateProcessW
