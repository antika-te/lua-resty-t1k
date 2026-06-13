# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build and Test Commands

```bash
# Lint Lua code
luacheck lib

# Run all tests (requires OpenResty and Test::Nginx)
prove -r t/

# Run a single test file
prove t/handler.t

# Run integration tests (requires DETECTOR_IP env var)
DETECTOR_IP=<ip> prove t/integration.t
```

## Project Overview

lua-resty-t1k is a Lua implementation of the T1K binary protocol for integrating OpenResty/nginx with Chaitin/SafeLine Web Application Firewall. It sends HTTP request metadata to a WAF detection service and handles block/allow decisions.

## Architecture

### Public API (`lib/resty/t1k.lua`)

Two main entry points:
- `t1k.do_access(t, handle)` - Called in `access_by_lua_block`. Sends request to WAF, optionally handles blocking.
- `t1k.do_header_filter()` - Called in `header_filter_by_lua_block`. Injects extra headers from WAF response.

### T1K Protocol Flow (`lib/resty/t1k/request.lua`)

1. **Build request parts**: HTTP headers (`build_header`), body (`build_body`), metadata (`build_extra`)
2. **Send to WAF**: Connect via TCP or Unix socket, send tagged binary packets
3. **Parse response**: Receive tagged response packets with action code

### Key Modules

| Module | Purpose |
|--------|---------|
| `constants.lua` | Protocol tags (TAG_HEAD, TAG_BODY, TAG_EXTRA), masks (MASK_FIRST, MASK_LAST), modes |
| `handler.lua` | Interprets WAF response: `.` = passed, `?` = blocked. Sets HTTP status and returns JSON block page. |
| `filter.lua` | Parses extra headers from WAF response and injects into ngx.header |
| `utils.lua` | Binary packet parsing, length encoding (little-endian 4-byte), variable extraction |
| `uuid.lua` | UUID v4 generation using OpenSSL RAND_bytes via FFI |
| `buffer.lua` | Simple table-based string builder for efficient concatenation |
| `file.lua` | Reads request body from temp files when body exceeds memory limits |

### Protocol Constants

```lua
-- Actions from WAF
ACTION_PASSED = "."   -- Request allowed
ACTION_BLOCKED = "?"  -- Request blocked

-- Modes
MODE_OFF = "off"      -- WAF disabled
MODE_BLOCK = "block"  -- Block malicious requests
MODE_MONITOR = "monitor"  -- Log only, don't block

-- Packet tags (first byte masked with FIRST/LAST flags)
TAG_HEAD = 0x01       -- HTTP headers
TAG_BODY = 0x02       -- Request body
TAG_EXTRA = 0x03      -- Metadata (UUID, IPs, ports, etc.)
```

### Packet Format

Each packet: `[tag byte (1)][length (4 bytes LE)][payload]`
- First packet has `MASK_FIRST (0x40)` OR'd into tag
- Last packet has `MASK_LAST (0x80)` OR'd into tag

## Test Framework

Tests use `Test::Nginx::Socket` (Perl). Each `.t` file defines test cases with:
- Nginx config blocks
- Mock TCP responses (`tcp_reply`) for unit tests
- Real detector service for integration tests

Unit tests in `t/request.t`, `t/handler.t`, etc. mock the WAF server with `tcp_listen`/`tcp_reply`. Integration tests (`t/integration.t`) require a running SafeLine detector container.
