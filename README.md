# lua-resty-t1k

[![LuaRocks](https://img.shields.io/luarocks/v/blaisewang/lua-resty-t1k?style=flat-square)](https://luarocks.org/modules/blaisewang/lua-resty-t1k)
[![Releases](https://img.shields.io/github/v/release/chaitin/lua-resty-t1k?style=flat-square)](https://github.com/chaitin/lua-resty-t1k/releases)
[![License](https://img.shields.io/github/license/chaitin/lua-resty-t1k?color=ff69b4&style=flat-square)](https://github.com/chaitin/lua-resty-t1k/blob/main/LICENSE)

## Name

Lua implementation of the T1K protocol for [Chaitin/SafeLine](https://github.com/chaitin/safeline) Web Application Firewall.

## Status

Production ready.

[![Test](https://img.shields.io/github/actions/workflow/status/chaitin/lua-resty-t1k/test.yml?logo=github&style=flat-square)](https://github.com/chaitin/lua-resty-t1k/actions)

## Installation

```bash
luarocks install lua-resty-t1k
```

If you are in Mainland China

```bash
luarocks install lua-resty-t1k --server https://luarocks.cn
```

## Synopsis

```lua
location / {
    access_by_lua_block {
        local t1k = require "resty.t1k"

        local t = {
            mode = "block",                            -- block or monitor or off, default off
            host = "unix:/workdir/snserver.sock",      -- required, SafeLine WAF detection service host, unix domain socket, IP, or domain is supported, string
            port = 8000,                               -- required when the host is an IP or domain, SafeLine WAF detection service port, integer
            connect_timeout = 1000,                    -- connect timeout, in milliseconds, integer, default 1s (1000ms)
            send_timeout = 1000,                       -- send timeout, in milliseconds, integer, default 1s (1000ms)
            read_timeout = 1000,                       -- read timeout, in milliseconds, integer, default 1s (1000ms)
            req_body_size = 1024,                      -- request body size, in KB, integer, default 1MB (1024KB)
            keepalive_size = 256,                      -- maximum concurrent idle connections to the SafeLine WAF detection service, integer, default 256
            keepalive_timeout = 60000,                 -- idle connection timeout, in milliseconds, integer, default 60s (60000ms)
            remote_addr = "http_x_forwarded_for: 1",   -- remote address from ngx.var.VARIABLE, string, default from ngx.var.remote_addr
        }

        local ok, err, _ = t1k.do_access(t, true)
        if not ok then 
            ngx.log(ngx.ERR, err)
        end
    }

    header_filter_by_lua_block {
        local t1k = require "resty.t1k"
        t1k.do_header_filter()
    }
}
```

## Multi-Node and Response Detection (v1.2.0+)

### Multi-Node Failover

```lua
local t = {
    mode = "block",
    servers = {
        { host = "192.168.1.10", port = 8000 },
        { host = "192.168.1.11", port = 8000, max_fails = 3, fail_timeout = 30 },
        { host = "unix:/var/run/detector.sock" },
    },
    -- ... other options
}
```

When multiple servers are configured, the module automatically fails over to the next healthy server on connection failure. Unhealthy servers are retried after `fail_timeout` seconds.

### Response Detection

Zero-config for monitor mode. Block mode requires one `include` line.

```lua
local t = {
    mode = "block",
    host = "127.0.0.1",
    port = 8000,
    response_mode = "monitor",   -- "monitor" (zero config) or "block" (needs include)
    rsp_body_size = 4096,        -- max response body bytes to inspect, default 4096
}
```

**Monitor mode** (zero config): Logs blocked responses via `ngx.log(WARN, ...)` but does not intercept.

**Block mode**: Add one line to nginx.conf http block to enable response interception:

```nginx
# nginx.conf http block
include /path/to/lua-resty-t1k/t1k_rsp.conf;
```

Then add `body_filter_by_lua_block`:

```nginx
location / {
    access_by_lua_block { ... }

    header_filter_by_lua_block {
        local t1k = require "resty.t1k"
        t1k.do_header_filter()
    }

    body_filter_by_lua_block {
        local t1k = require "resty.t1k"
        t1k.do_body_filter()
    }
}
```

### Proxy Mode (Zero Config)

An alternative approach inspired by [t1k-go](https://github.com/chaitin/t1k-go). Use `content_by_lua_block` instead of `proxy_pass` to control the entire request/response flow. No nginx config changes required.

```nginx
location / {
    content_by_lua_block {
        local proxy = require "resty.t1k.proxy"
        proxy.pass({
            -- Detector config
            mode          = "block",
            host          = "127.0.0.1",
            port          = 8000,

            -- Multi-node (optional)
            -- servers = {
            --     { host = "10.0.0.1", port = 8000 },
            --     { host = "10.0.0.2", port = 8000 },
            -- },

            -- Active health check (optional)
            -- health_check = {
            --     interval            = 10,    -- check interval in seconds
            --     timeout             = 3000,  -- connect/read timeout in ms
            --     healthy_threshold   = 2,     -- consecutive successes to mark healthy
            --     unhealthy_threshold = 2,     -- consecutive failures to mark unhealthy
            -- },

            -- Backend upstream
            backend       = "127.0.0.1:8080",

            -- Response detection
            response_mode = "block",
            rsp_body_size = 4096,

            -- Common options
            connect_timeout   = 1000,
            send_timeout      = 1000,
            read_timeout      = 1000,
            req_body_size     = 1024,
            keepalive_size    = 256,
            keepalive_timeout = 60000,
        })
    }
}
```

Proxy mode supports request detection, response detection with blocking, multi-node failover, and active health checks — all without modifying nginx.conf.

| Feature | access+filter mode | proxy mode |
|---------|-------------------|------------|
| Request detection & block | ✅ | ✅ |
| Response detection monitor | ✅ zero config | ✅ zero config |
| Response detection block | ❌ needs include | ✅ zero config |
| Active health check | ❌ | ✅ |
| Multi-node failover | ✅ | ✅ |

### Active Health Check

Available in proxy mode. The `health_check` option spawns a background timer that periodically probes each detector node using the T1K heartbeat protocol.

```lua
proxy.pass({
    servers = {
        { host = "10.0.0.1", port = 8000 },
        { host = "10.0.0.2", port = 8000 },
    },
    health_check = {
        interval            = 10,    -- seconds between checks
        timeout             = 3000,  -- ms, connect/read timeout
        healthy_threshold   = 2,     -- consecutive OKs to mark healthy
        unhealthy_threshold = 2,     -- consecutive failures to mark unhealthy
    },
    -- ... other options
})
```

- Passively, `max_fails` consecutive request failures will also mark a server unhealthy
- Unhealthy servers are automatically retried after `fail_timeout` seconds
- Health check runs once per worker, started on the first request

## Lua Resty T1K vs. C T1K

[C T1K](https://t1k.chaitin.com/), as part of SafeLine's enterprise edition, is a deployment mode crafted in C language for enhanced performance.
It is compatible with all versions of Nginx and does not require deployment via OpenResty (lua_nginx_module).

|                       | Lua Resty T1K | C T1K |
|-----------------------|---------------|-------|
| Request Detection     | ✅             | ✅     |
| Response Detection    | ✅             | ✅     |
| Health Checks         | ✅             | ✅     |
| Cookie Protection     | ❌             | ✅     |
| Bot Protection        | ❌             | ✅     |
| Proxy-side Statistics | ❌             | ✅     |
