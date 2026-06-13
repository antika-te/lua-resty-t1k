local consts = require "resty.t1k.constants"
local log = require "resty.t1k.log"

local fmt = string.format
local char = string.char
local byte = string.byte
local insert = table.insert

local bor = bit.bor

local ngx = ngx
local nlog = ngx.log

local log_fmt = log.fmt
local debug_fmt = log.debug_fmt

local _M = {
    _VERSION = '1.0.0'
}

local DEFAULT_MAX_FAILS = 3
local DEFAULT_FAIL_TIMEOUT = 30

function _M.new(servers)
    if not servers or #servers == 0 then
        return nil, "no servers configured"
    end

    local pool = {
        servers = {},
        index = 1,
    }

    for i, server in ipairs(servers) do
        if not server.host then
            return nil, fmt("server %d missing host", i)
        end

        local normalized = {
            host = server.host,
            port = server.port,
            uds = server.host:sub(1, 5) == "unix:",
            weight = server.weight or 1,
            max_fails = server.max_fails or DEFAULT_MAX_FAILS,
            fail_timeout = server.fail_timeout or DEFAULT_FAIL_TIMEOUT,

            fails = 0,
            last_fail_time = 0,
        }

        if not normalized.uds and not normalized.port then
            return nil, fmt("server %d missing port", i)
        end

        insert(pool.servers, normalized)
    end

    return pool
end

local function is_healthy(server)
    if server.fails < server.max_fails then
        return true
    end

    local now = ngx.now()
    if now - server.last_fail_time > server.fail_timeout then
        server.fails = 0
        return true
    end

    return false
end

local function mark_failed(server)
    server.fails = server.fails + 1
    server.last_fail_time = ngx.now()
end

local function mark_success(server)
    server.fails = 0
end

function _M.select(pool)
    local servers = pool.servers
    local count = #servers

    local start_idx = pool.index
    local selected = nil

    for i = 1, count do
        local idx = ((start_idx + i - 2) % count) + 1
        local server = servers[idx]

        if is_healthy(server) then
            pool.index = (idx % count) + 1
            selected = server
            break
        end
    end

    if not selected then
        pool.index = (start_idx % count) + 1
        selected = servers[start_idx]
        selected.fails = 0
    end

    return selected
end

function _M.select_all_healthy(pool)
    local healthy = {}
    for _, server in ipairs(pool.servers) do
        if is_healthy(server) then
            insert(healthy, server)
        end
    end

    if #healthy == 0 then
        for _, server in ipairs(pool.servers) do
            server.fails = 0
            insert(healthy, server)
        end
    end

    return healthy
end

_M.mark_failed = mark_failed
_M.mark_success = mark_success
_M.is_healthy = is_healthy

function _M.server_key(server)
    if server.uds then
        return server.host
    else
        return fmt("%s:%d", server.host, server.port)
    end
end

-- Active health check via T1K heartbeat protocol.
-- Sends empty packet with MASK_FIRST|MASK_LAST, expects any response.
local HEARTBEAT_HEADER = char(bor(consts.MASK_FIRST, consts.MASK_LAST)) .. "\x00\x00\x00\x00"

local function check_server(server, timeout)
    local sock, err = ngx.socket.tcp()
    if not sock then
        return false, fmt("create socket: %s", err)
    end

    sock:settimeouts(timeout, timeout, timeout)

    local ok, err
    if server.uds then
        ok, err = sock:connect(server.host)
    else
        ok, err = sock:connect(server.host, server.port)
    end
    if not ok then
        sock:close()
        return false, fmt("connect: %s", err)
    end

    local bytes, err = sock:send(HEARTBEAT_HEADER)
    if not bytes then
        sock:close()
        return false, fmt("send heartbeat: %s", err)
    end

    -- Read any response to confirm detector is alive
    local data, err = sock:receive(1)
    sock:close()

    if not data then
        return false, fmt("receive heartbeat: %s", err)
    end

    return true, nil
end

function _M.start_health_check(pool, opts)
    if pool._health_check_started then
        return
    end
    pool._health_check_started = true

    opts = opts or {}
    local interval = opts.interval or 10       -- seconds between checks
    local timeout = opts.timeout or 3000       -- ms, connect/read timeout
    local unhealthy_threshold = opts.unhealthy_threshold or 2
    local healthy_threshold = opts.healthy_threshold or 2

    local servers = pool.servers
    local consecutive_results = {}
    for i = 1, #servers do
        consecutive_results[i] = { ok = 0, fail = 0 }
    end

    local function run_check(premature)
        if premature then return end

        for i, server in ipairs(servers) do
            local ok, err = check_server(server, timeout)
            local r = consecutive_results[i]

            if ok then
                r.ok = r.ok + 1
                r.fail = 0
                nlog(debug_fmt("health check OK: %s", _M.server_key(server)))
                if r.ok >= healthy_threshold then
                    server.fails = 0
                    r.ok = 0
                end
            else
                r.fail = r.fail + 1
                r.ok = 0
                nlog(log_fmt("health check FAIL: %s: %s", _M.server_key(server), err))
                if r.fail >= unhealthy_threshold then
                    server.fails = server.max_fails
                    server.last_fail_time = ngx.now()
                end
            end
        end

        ngx.timer.at(interval, run_check)
    end

    ngx.timer.at(interval, run_check)
end

return _M
