local consts = require "resty.t1k.constants"
local log = require "resty.t1k.log"
local utils = require "resty.t1k.utils"

local fmt = string.format
local char = string.char
local byte = string.byte
local bor = bit.bor
local ngx = ngx
local nlog = ngx.log
local debug_fmt = log.debug_fmt

local _M = {
    _VERSION = '1.0.0'
}

local TAG_HEAD_WITH_MASK_FIRST = bor(consts.TAG_HEAD, consts.MASK_FIRST)
local TAG_CONTEXT_WITH_MASK_LAST = bor(consts.TAG_CONTEXT, consts.MASK_LAST)

local function build_response_header(rsp_status, rsp_headers)
    local status = rsp_status or ngx.status or 200
    local status_line = fmt("HTTP/1.1 %d OK\r\n", status)

    local buf = { status_line }

    local headers = rsp_headers or ngx.resp.get_headers(0, true)
    if headers then
        for k, v in pairs(headers) do
            if type(v) == "table" then
                buf[#buf + 1] = fmt("%s: %s\r\n", k, table.concat(v, ", "))
            else
                buf[#buf + 1] = fmt("%s: %s\r\n", k, v)
            end
        end
    end
    buf[#buf + 1] = "\r\n"

    return table.concat(buf)
end

local function build_response_body(ctx)
    local body = ctx.t1k_rsp_body
    if not body then
        return nil
    end

    if type(body) == "table" then
        return table.concat(body)
    end

    return body
end

local function build_response_extra(ctx)
    local uuid = ctx.t1k_uuid or ""
    local rsp_begin_time = ctx.t1k_rsp_begin_time or 0

    local extra = fmt("%s:%s\n%s:%s\n%s:%d\n%s:%d\n%s:%s\n%s:%s\n%s:%d\n",
        consts.KEY_EXTRA_SCHEME, ngx.var.scheme or "http",
        consts.KEY_EXTRA_REMOTE_ADDR, ngx.var.remote_addr or "127.0.0.1",
        consts.KEY_EXTRA_REMOTE_PORT, tonumber(ngx.var.remote_port) or 0,
        consts.KEY_EXTRA_LOCAL_PORT, tonumber(ngx.var.server_port) or 0,
        consts.KEY_EXTRA_LOCAL_ADDR, ngx.var.server_addr or "127.0.0.1",
        consts.KEY_EXTRA_UUID, uuid,
        consts.KEY_EXTRA_RSP_BEGIN_TIME, rsp_begin_time
    )

    return extra
end

local function do_send(sock, data)
    local ok, err = sock:send(data)
    if not ok then
        return ok, err
    end
    return true, nil
end

local function receive_data(s, srv)
    local t = {}
    local ft = true
    local finished

    repeat
        local err
        local tag, length, packet, rsp_body

        packet, err = s:receive(consts.T1K_HEADER_SIZE)
        if err then
            err = fmt("failed to receive info packet from t1k server %s: %s", srv, err)
            return nil, err, nil
        end
        if not packet then
            err = fmt("empty packet from t1k server %s", srv)
            return nil, err, nil
        end

        if ft then
            if not utils.is_mask_first(byte(packet, 1, 1)) then
                err = fmt("first packet is not MASK_FIRST from t1k server %s", srv)
                return nil, err, nil
            end
            ft = false
        end

        finished, tag, length = utils.packet_parser(packet)
        if length > 0 then
            rsp_body, err = s:receive(length)
            if not rsp_body or #rsp_body ~= length then
                err = fmt("failed to receive payload from t1k server %s: %s", srv, err)
                return nil, err, nil
            end
            t[tag] = rsp_body
        end

    until (finished)

    return true, nil, t
end

local function get_socket(opts)
    local ok, err
    local sock, server

    sock, err = ngx.socket.tcp()
    if not sock then
        err = fmt("failed to create socket: %s", err)
        return nil, err, nil
    end

    sock:settimeouts(opts.connect_timeout, opts.send_timeout, opts.read_timeout)

    if opts.uds then
        server = opts.host
        ok, err = sock:connect(opts.host)
    else
        server = fmt("%s:%d", opts.host, opts.port)
        ok, err = sock:connect(opts.host, opts.port)
    end
    if not ok then
        sock:close()
        err = fmt("failed to connect to t1k server %s: %s", server, err)
        return nil, err, nil
    end
    nlog(debug_fmt("successfully connected to t1k server %s for response detection", server))

    return true, nil, sock, server
end

function _M.do_response_detect(opts, ctx)
    local ok, err, t, srv
    local sock, server

    local t1k_context = ctx.t1k_context or ""
    local raw_request_header = ctx.t1k_raw_request_header

    if not raw_request_header then
        local http_version = ngx.req.http_version()
        if not http_version or http_version < 2.0 then
            raw_request_header = ngx.req.raw_header()
        else
            local headers = ngx.req.get_headers(0, true)
            local buf = { fmt("%s %s HTTP/%.1f\r\n", ngx.req.get_method(), ngx.var.request_uri, http_version) }
            for k, v in pairs(headers) do
                if type(v) == "table" then
                    buf[#buf + 1] = fmt("%s: %s\r\n", k, table.concat(v, ", "))
                else
                    buf[#buf + 1] = fmt("%s: %s\r\n", k, v)
                end
            end
            buf[#buf + 1] = "\r\n"
            raw_request_header = table.concat(buf)
        end
    end

    local response_header = build_response_header(ctx.t1k_rsp_status, ctx.t1k_rsp_headers)
    local response_body = build_response_body(ctx)
    local response_extra = build_response_extra(ctx)

    ok, err, sock, server = get_socket(opts)
    if not ok then
        return ok, err, nil
    end

    local T1K_PROTO = "Proto:2\n"
    local T1K_PROTO_DATA = fmt("%s%s%s", char(consts.TAG_VERSION), utils.int_to_char_length(#T1K_PROTO), T1K_PROTO)

    ok, err = do_send(sock, { char(TAG_HEAD_WITH_MASK_FIRST), utils.int_to_char_length(#raw_request_header), raw_request_header })
    if not ok then
        sock:close()
        err = fmt("failed to send request header to t1k server %s: %s", server, err)
        return nil, err, nil
    end

    ok, err = do_send(sock, { char(consts.TAG_RSP_HEAD), utils.int_to_char_length(#response_header), response_header })
    if not ok then
        sock:close()
        err = fmt("failed to send response header to t1k server %s: %s", server, err)
        return nil, err, nil
    end

    if response_body and #response_body > 0 then
        ok, err = do_send(sock, { char(consts.TAG_RSP_BODY), utils.int_to_char_length(#response_body), response_body })
        if not ok then
            sock:close()
            err = fmt("failed to send response body to t1k server %s: %s", server, err)
            return nil, err, nil
        end
    end

    ok, err = do_send(sock, { char(consts.TAG_RSP_EXTRA), utils.int_to_char_length(#response_extra), response_extra })
    if not ok then
        sock:close()
        err = fmt("failed to send response extra to t1k server %s: %s", server, err)
        return nil, err, nil
    end

    ok, err = do_send(sock, { T1K_PROTO_DATA, char(TAG_CONTEXT_WITH_MASK_LAST), utils.int_to_char_length(#t1k_context), t1k_context })
    if not ok then
        sock:close()
        err = fmt("failed to send context to t1k server %s: %s", server, err)
        return nil, err, nil
    end

    ok, err, t = receive_data(sock, server)
    if not ok then
        return ok, err, nil
    end

    ok, err = sock:setkeepalive(opts.keepalive_timeout, opts.keepalive_size)
    if not ok then
        sock:close()
    end

    local result = {
        action = t[consts.TAG_HEAD],
        status = t[consts.TAG_BODY],
        event_id = utils.get_event_id(t[consts.TAG_EXTRA_BODY]),
    }

    return true, nil, result
end

return _M
