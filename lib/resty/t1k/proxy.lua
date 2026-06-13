local consts = require "resty.t1k.constants"
local handler = require "resty.t1k.handler"
local log = require "resty.t1k.log"
local request = require "resty.t1k.request"
local response = require "resty.t1k.response"
local server_pool = require "resty.t1k.server_pool"
local utils = require "resty.t1k.utils"

local fmt = string.format
local lower = string.lower
local tonumber = tonumber

local ngx = ngx
local nlog = ngx.log
local ngx_re = ngx.re
local log_fmt = log.fmt

local _M = {
    _VERSION = '1.0.0'
}

local DEFAULT_BACKEND_CONNECT_TIMEOUT = 5000
local DEFAULT_BACKEND_SEND_TIMEOUT = 60000
local DEFAULT_BACKEND_READ_TIMEOUT = 60000

local function build_backend_request()

    local method = ngx.req.get_method()
    local uri = ngx.var.request_uri
    local http_version = ngx.req.http_version() or 1.1

    local buf = { fmt("%s %s HTTP/%.1f\r\n", method, uri, http_version) }

    local headers, err = ngx.req.get_headers()
    if not headers then
        return nil, err
    end

    local skip_headers = {
        ["connection"] = true,
        ["keep-alive"] = true,
        ["proxy-connection"] = true,
        ["transfer-encoding"] = true,
    }

    for k, v in pairs(headers) do
        if not skip_headers[lower(k)] then
            if type(v) == "table" then
                buf[#buf + 1] = fmt("%s: %s\r\n", k, table.concat(v, ", "))
            else
                buf[#buf + 1] = fmt("%s: %s\r\n", k, v)
            end
        end
    end
    -- Force connection close so receive works
    buf[#buf + 1] = "Connection: close\r\n"
    buf[#buf + 1] = "\r\n"

    return table.concat(buf)
end

local function get_backend_body()
    ngx.req.read_body()
    return ngx.req.get_body_data()
end

local function parse_backend_response(data)
    local header_end = data:find("\r\n\r\n", 1, true)
    if not header_end then
        return nil, "failed to parse backend response: no header end"
    end

    local header_part = data:sub(1, header_end - 1)
    local body = data:sub(header_end + 4)

    local lines = {}
    for line in header_part:gmatch("[^\r\n]+") do
        lines[#lines + 1] = line
    end

    if #lines == 0 then
        return nil, "empty response header"
    end

    local status_line = lines[1]
    local status = tonumber(status_line:match("HTTP/%d%.%d%s+(%d+)")) or 200

    local res_headers = {}
    for i = 2, #lines do
        local k, v = lines[i]:match("^([^:]+):%s*(.*)$")
        if k and v then
            res_headers[k] = v
        end
    end

    return {
        status = status,
        status_line = status_line,
        headers = res_headers,
        body = body,
        raw = data,
    }
end

local function parse_detector_response(detector_data)
    local tag_head = detector_data[consts.TAG_HEAD]
    local tag_body = detector_data[consts.TAG_BODY]
    local tag_extra_body = detector_data[consts.TAG_EXTRA_BODY]

    return {
        action = tag_head,
        status = tonumber(tag_body) or ngx.HTTP_FORBIDDEN,
        event_id = utils.get_event_id(tag_extra_body),
    }
end

function _M.pass(t)
    t = t or {}

    if not t.backend then
        ngx.status = 500
        ngx.say("t1k proxy: no backend configured")
        return
    end

    local backend_addr = t.backend

    -- Build detection opts (same structure as do_access expects)
    local opts = {
        mode = lower(t.mode or consts.MODE_OFF),
    }

    if opts.mode == consts.MODE_OFF then
        -- No detection, just proxy
        _M.proxy_only(backend_addr)
        return
    end

    -- Setup server config
    if t.servers then
        opts.servers = t.servers
    elseif t.host then
        opts.host = t.host
        opts.port = tonumber(t.port)
        if utils.starts_with(opts.host, consts.UNIX_SOCK_PREFIX) then
            opts.uds = true
        end
    else
        ngx.status = 500
        ngx.say("t1k proxy: no detector host configured")
        return
    end

    opts.connect_timeout = t.connect_timeout or 1000
    opts.send_timeout = t.send_timeout or 1000
    opts.read_timeout = t.read_timeout or 1000
    opts.req_body_size = t.req_body_size or 1024
    opts.keepalive_size = t.keepalive_size or 256
    opts.keepalive_timeout = t.keepalive_timeout or 60000

    local resp_mode = lower(t.response_mode or consts.MODE_OFF)
    if resp_mode ~= consts.MODE_BLOCK and resp_mode ~= consts.MODE_MONITOR then
        resp_mode = consts.MODE_OFF
    end

    if t.remote_addr then
        local var, idx = utils.to_var_idx(t.remote_addr)
        opts.remote_addr_var = var
        opts.remote_addr_idx = idx
    end

    -- Start active health check for multi-node setups
    if t.health_check and opts.servers then
        local pool = server_pool.new(opts.servers)
        server_pool.start_health_check(pool, t.health_check)
    end

    -- Phase 1: Request detection
    local req_ok, req_err, req_result = request.do_request(opts)
    if not req_ok then
        ngx.status = 500
        ngx.say(req_err)
        return
    end

    if opts.mode == consts.MODE_BLOCK and req_result.action == consts.ACTION_BLOCKED then
        nlog(ngx.ERR, log_fmt("request blocked: event_id=%s", req_result.event_id or ""))
        handler.handle(req_result)
        return
    elseif req_result.action == consts.ACTION_PASSED then
        nlog(ngx.ERR, log_fmt("request passed: action=%s", req_result.action))
    end

    -- Phase 2: Fetch backend response
    local backend_ok, backend_res, backend_err = _M.fetch_backend(backend_addr)
    if not backend_ok then
        ngx.status = 502
        ngx.say("backend error: ", backend_err)
        return
    end

    -- Phase 3: Response detection
    if resp_mode ~= consts.MODE_OFF then
        local ctx = ngx.ctx
        local t1k_context = ctx.t1k_context or ""

        -- Build request header as string for response detection
        local raw_request_header = build_backend_request():gsub("\r\n\r\n$", "")

        local rsp_ctx = {
            t1k_context = t1k_context,
            t1k_raw_request_header = raw_request_header,
            t1k_rsp_body = backend_res.body,
            t1k_rsp_begin_time = ngx.now() * 1e6,
        }

        -- Get UUID from ctx if available
        rsp_ctx.t1k_uuid = ngx.var.t1k_uuid or ""

        local rsp_ok, rsp_err, rsp_result = response.do_response_detect(opts, rsp_ctx)

        if rsp_ok and rsp_result and rsp_result.action == consts.ACTION_BLOCKED then
            nlog(ngx.WARN, log_fmt("response blocked: event_id=%s", rsp_result.event_id or ""))

            if resp_mode == consts.MODE_BLOCK then
                handler.handle(rsp_result)
                return
            end
        elseif rsp_ok and rsp_result then
            nlog(ngx.ERR, log_fmt("response passed: action=%s", rsp_result.action))
        elseif not rsp_ok then
            nlog(log_fmt("response detection error: %s", rsp_err or "unknown"))
        end
    end

    -- Phase 4: Forward response to client
    ngx.status = backend_res.status
    for k, v in pairs(backend_res.headers) do
        ngx.header[k] = v
    end
    if backend_res.body then
        ngx.header["Content-Length"] = #backend_res.body
    end
    ngx.print(backend_res.body)
end

-- Parse backend URL like "http://127.0.0.1:8080" or "127.0.0.1:8080"
function _M.parse_backend_url(url)
    local host, port, ssl
    local schema, rest = url:match("^(https?)://(.+)$")
    if schema then
        ssl = (schema == "https")
        url = rest
    end
    host, port = url:match("^([^:]+):(%d+)$")
    if not host then
        host = url
        port = ssl and 443 or 80
    else
        port = tonumber(port)
    end
    return host, port, ssl
end

function _M.fetch_backend(url)
    local host, port, ssl = _M.parse_backend_url(url)

    local sock, err = ngx.socket.tcp()
    if not sock then
        return nil, nil, fmt("create socket: %s", err)
    end

    sock:settimeouts(DEFAULT_BACKEND_CONNECT_TIMEOUT, DEFAULT_BACKEND_SEND_TIMEOUT, DEFAULT_BACKEND_READ_TIMEOUT)

    local ok, err = sock:connect(host, port)
    if not ok then
        sock:close()
        return nil, nil, fmt("connect to backend %s:%d: %s", host, port, err)
    end

    if ssl then
        local ok, err = sock:sslhandshake(nil, host, false)
        if not ok then
            sock:close()
            return nil, nil, fmt("ssl handshake: %s", err)
        end
    end

    local req_data = build_backend_request()
    local body = get_backend_body()

    local bytes, err = sock:send(req_data)
    if not bytes then
        sock:close()
        return nil, nil, fmt("send request: %s", err)
    end

    if body then
        ok, err = sock:send(body)
        if not ok then
            sock:close()
            return nil, nil, fmt("send body: %s", err)
        end
    end

    local data, err = sock:receive("*a")
    if not data then
        sock:close()
        return nil, nil, fmt("receive response: %s", err)
    end

    sock:close()

    local res, err = parse_backend_response(data)
    if not res then
        return nil, nil, err
    end

    return true, res
end

function _M.proxy_only(url)
    local ok, res, err = _M.fetch_backend(url)
    if not ok then
        ngx.status = 502
        ngx.say("backend error: ", err)
        return
    end

    ngx.status = res.status
    for k, v in pairs(res.headers) do
        ngx.header[k] = v
    end
    ngx.print(res.body)
end

return _M
