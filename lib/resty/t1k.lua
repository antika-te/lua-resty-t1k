local consts = require "resty.t1k.constants"
local filter = require "resty.t1k.filter"
local handler = require "resty.t1k.handler"
local log = require "resty.t1k.log"
local request = require "resty.t1k.request"
local utils = require "resty.t1k.utils"

local lower = string.lower

local ngx = ngx
local nlog = ngx.log

local log_fmt = log.fmt
local debug_fmt = log.debug_fmt

local _M = {
    _VERSION = '1.0.0'
}

local DEFAULT_T1K_CONNECT_TIMEOUT = 1000 -- 1s
local DEFAULT_T1K_SEND_TIMEOUT = 1000 -- 1s
local DEFAULT_T1K_READ_TIMEOUT = 1000 -- 1s
local DEFAULT_T1K_REQ_BODY_SIZE = 1024 -- 1024 KB
local DEFAULT_T1K_KEEPALIVE_SIZE = 256
local DEFAULT_T1K_KEEPALIVE_TIMEOUT = 60 * 1000 -- 60s
local DEFAULT_T1K_RSP_BODY_SIZE = 4096 -- 4096 bytes

local uuid = require "resty.t1k.uuid"

function _M.do_access(t, handle)
    local ok, err, result
    local opts = {}
    t = t or {}

    if not t.mode then
        return true, nil, nil
    end

    opts.mode = lower(t.mode)
    if opts.mode == consts.MODE_OFF then
        nlog(debug_fmt("t1k is not enabled"))
        return true, nil, nil
    end

    if opts.mode ~= consts.MODE_OFF and opts.mode ~= consts.MODE_BLOCK and opts.mode ~= consts.MODE_MONITOR then
        err = log_fmt("invalid t1k mode: %s", t.mode)
        return nil, err, nil
    end

    -- Support both legacy host/port and new servers array
    if t.servers then
        if type(t.servers) ~= "table" or #t.servers == 0 then
            err = log_fmt("invalid t1k servers: empty or not a table")
            return nil, err, nil
        end
        for i, server in ipairs(t.servers) do
            if not server.host then
                err = log_fmt("server %d missing host", i)
                return nil, err, nil
            end
            if server.host and not utils.starts_with(server.host, consts.UNIX_SOCK_PREFIX) then
                if not tonumber(server.port) then
                    err = log_fmt("server %d missing port", i)
                    return nil, err, nil
                end
            end
        end
        opts.servers = t.servers
    else
        if not t.host then
            err = log_fmt("invalid t1k host: %s", t.host)
            return nil, err, nil
        end
        opts.host = t.host

        if utils.starts_with(opts.host, consts.UNIX_SOCK_PREFIX) then
            opts.uds = true
        else
            if not tonumber(t.port) then
                err = log_fmt("invalid t1k port: %s", t.port)
                return nil, err, nil
            end
            opts.port = tonumber(t.port)
        end
    end

    opts.connect_timeout = t.connect_timeout or DEFAULT_T1K_CONNECT_TIMEOUT
    opts.send_timeout = t.send_timeout or DEFAULT_T1K_SEND_TIMEOUT
    opts.read_timeout = t.read_timeout or DEFAULT_T1K_READ_TIMEOUT
    opts.req_body_size = t.req_body_size or DEFAULT_T1K_REQ_BODY_SIZE
    opts.keepalive_size = t.keepalive_size or DEFAULT_T1K_KEEPALIVE_SIZE
    opts.keepalive_timeout = t.keepalive_timeout or DEFAULT_T1K_KEEPALIVE_TIMEOUT

    -- Response detection options
    opts.response_mode = lower(t.response_mode or consts.MODE_OFF)
    if opts.response_mode ~= consts.MODE_OFF and opts.response_mode ~= consts.MODE_BLOCK and opts.response_mode ~= consts.MODE_MONITOR then
        opts.response_mode = consts.MODE_OFF
    end
    opts.rsp_body_size = t.rsp_body_size or DEFAULT_T1K_RSP_BODY_SIZE

    -- Store context for response detection
    local ctx = ngx.ctx
    ctx.t1k_uuid = uuid.generate_v4()
    ctx.t1k_rsp_body_size = opts.rsp_body_size
    ctx.t1k_rsp_mode = opts.response_mode
    ctx.t1k_rsp_begin_time = ngx.now() * 1000000

    -- Store server config for internal response detection
    ctx.t1k_servers = opts.servers
    ctx.t1k_host = opts.host
    ctx.t1k_port = opts.port
    ctx.t1k_uds = opts.uds
    ctx.t1k_connect_timeout = opts.connect_timeout
    ctx.t1k_send_timeout = opts.send_timeout
    ctx.t1k_read_timeout = opts.read_timeout
    ctx.t1k_keepalive_size = opts.keepalive_size
    ctx.t1k_keepalive_timeout = opts.keepalive_timeout

    if t.remote_addr then
        local var, idx = utils.to_var_idx(t.remote_addr)
        opts.remote_addr_var = var
        opts.remote_addr_idx = idx
    end

    ok, err, result = request.do_request(opts)
    if not ok then
        return ok, err, result
    end

    if handle and opts.mode == consts.MODE_BLOCK then
        ok, err = _M.do_handle(result)
    end

    return ok, err, result
end

function _M.do_handle(t)
    local ok, err = handler.handle(t)
    return ok, err
end

function _M.do_header_filter()
    filter.do_header_filter()
end

function _M.do_body_filter()
    local ctx = ngx.ctx

    if ctx.t1k_rsp_mode == consts.MODE_OFF or ctx.t1k_rsp_mode == nil then
        return
    end

    if ctx.t1k_blocked then
        return
    end

    local chunk = ngx.arg[1]
    local eof = ngx.arg[2]

    if not ctx.t1k_rsp_body_chunks then
        ctx.t1k_rsp_body_chunks = {}
        ctx.t1k_rsp_body_len = 0
    end

    local max_size = ctx.t1k_rsp_body_size or DEFAULT_T1K_RSP_BODY_SIZE

    if chunk then
        if ctx.t1k_rsp_body_len < max_size then
            local remaining = max_size - ctx.t1k_rsp_body_len
            local to_add = #chunk < remaining and chunk or chunk:sub(1, remaining)
            ctx.t1k_rsp_body_chunks[#ctx.t1k_rsp_body_chunks + 1] = to_add
            ctx.t1k_rsp_body_len = ctx.t1k_rsp_body_len + #to_add
        end
    end

    if not eof then
        return
    end

    -- Monitor mode: use timer (zero config, cannot block)
    if ctx.t1k_rsp_mode == consts.MODE_MONITOR then
        ctx.t1k_rsp_body = table.concat(ctx.t1k_rsp_body_chunks)
        ngx.timer.at(0, function()
            local opts = {
                connect_timeout = ctx.t1k_connect_timeout or 1000,
                send_timeout = ctx.t1k_send_timeout or 1000,
                read_timeout = ctx.t1k_read_timeout or 1000,
                keepalive_size = ctx.t1k_keepalive_size or 256,
                keepalive_timeout = ctx.t1k_keepalive_timeout or 60000,
            }
            if ctx.t1k_servers then
                opts.servers = ctx.t1k_servers
            elseif ctx.t1k_host then
                opts.host = ctx.t1k_host
                opts.port = ctx.t1k_port
                if ctx.t1k_uds then
                    opts.uds = true
                end
            else
                return
            end
            local response = require "resty.t1k.response"
            local ok, err, result = response.do_response_detect(opts, ctx)
            if ok and result and result.action == consts.ACTION_BLOCKED then
                ngx.log(ngx.WARN, log_fmt("response blocked (monitor mode): event_id=%s", result.event_id))
            end
        end)
        return
    end

    -- Block mode: use subrequest (requires internal location)
    local body = table.concat(ctx.t1k_rsp_body_chunks)

    local res = ngx.location.capture("/__t1k_rsp_detect", {
        method = ngx.HTTP_POST,
        body = body,
    })

    if not res or res.status ~= 200 then
        nlog(log_fmt("response detection failed: %s", res and res.status or "no response"))
        return
    end

    if res.body == "block" then
        ctx.t1k_blocked = true
        ngx.arg[1] = nil
        ngx.arg[2] = true
        ngx.status = ngx.HTTP_FORBIDDEN
    end
end

return _M
