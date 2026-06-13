local consts = require "resty.t1k.constants"
local log = require "resty.t1k.log"
local response = require "resty.t1k.response"

local ngx = ngx
local nlog = ngx.log
local log_fmt = log.fmt

local _M = {
    _VERSION = '1.0.0'
}

function _M.handle_internal_request()
    local ctx = ngx.ctx

    ngx.req.read_body()
    local rsp_body = ngx.req.get_body_data()

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
        ngx.status = 500
        ngx.say("no t1k server configured")
        return ngx.exit(500)
    end

    -- Store the response body in ctx for do_response_detect
    ctx.t1k_rsp_body = rsp_body

    local ok, err, result = response.do_response_detect(opts, ctx)

    if not ok then
        nlog(log_fmt("response detection failed: %s", err))
        ngx.status = 500
        ngx.say("detection failed")
        return ngx.exit(500)
    end

    if result.action == consts.ACTION_BLOCKED then
        ngx.status = 200
        ngx.say("block")
    else
        ngx.status = 200
        ngx.say("pass")
    end
end

return _M
