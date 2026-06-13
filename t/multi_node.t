use Test::Nginx::Socket;

our $HttpConfig = <<'_EOC_';
    lua_package_path "lib/?.lua;/usr/local/share/lua/5.1/?.lua;;";
_EOC_

repeat_each(3);

plan tests => repeat_each() * (blocks() * 3 + 4);

run_tests();

__DATA__

=== TEST 1: do_access with multiple servers - first succeeds
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local t1k = require "resty.t1k"

            local t = {
                mode = "block",
                servers = {
                    { host = "127.0.0.1", port = 18000 },
                    { host = "127.0.0.1", port = 18001 },
                },
                connect_timeout = 1000,
                send_timeout = 1000,
                read_timeout = 1000,
                req_body_size = 1024,
                keepalive_size = 16,
                keepalive_timeout = 10000,
            }

            local ok, err, result = t1k.do_access(t)
            if not ok then
                ngx.log(ngx.ERR, err)
            end

            ngx.say(result["action"])
            ngx.say(result["status"])
            ngx.say(result["event_id"])
        }
    }
--- tcp_listen: 18000
--- tcp_reply eval
"\x41\x01\x00\x00\x00?\x02\x03\x00\x00\x00405\xa4\x33\x00\x00\x00<!-- event_id: server1_event -->"
--- request
GET /t/shell.php
--- response_body
?
405
server1_event
--- no_error_log
[error]
--- error_log
successfully connected to t1k server 127.0.0.1:18000
--- log_level: debug



=== TEST 2: do_access with multiple servers - first fails, second succeeds
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local t1k = require "resty.t1k"

            local t = {
                mode = "block",
                servers = {
                    { host = "127.0.0.1", port = 18000, max_fails = 1 },
                    { host = "127.0.0.1", port = 18001 },
                },
                connect_timeout = 1000,
                send_timeout = 1000,
                read_timeout = 1000,
                req_body_size = 1024,
                keepalive_size = 16,
                keepalive_timeout = 10000,
            }

            local ok, err, result = t1k.do_access(t)
            if not ok then
                ngx.log(ngx.ERR, err)
            end

            ngx.say(result["action"])
            ngx.say(result["status"])
            ngx.say(result["event_id"])
        }
    }
--- tcp_listen: 18001
--- tcp_reply eval
"\x41\x01\x00\x00\x00?\x02\x03\x00\x00\x00405\xa4\x33\x00\x00\x00<!-- event_id: server2_event -->"
--- request
GET /t/shell.php
--- response_body
?
405
server2_event
--- no_error_log
[error]
--- error_log
successfully connected to t1k server 127.0.0.1:18001
--- log_level: debug



=== TEST 3: do_access with multiple servers - all fail
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local t1k = require "resty.t1k"

            local t = {
                mode = "block",
                servers = {
                    { host = "127.0.0.1", port = 18000, max_fails = 1 },
                    { host = "127.0.0.1", port = 18001, max_fails = 1 },
                },
                connect_timeout = 100,
                send_timeout = 100,
                read_timeout = 100,
                req_body_size = 1024,
                keepalive_size = 16,
                keepalive_timeout = 10000,
            }

            local ok, err, result = t1k.do_access(t)
            if not ok then
                ngx.log(ngx.ERR, err)
            end

            ngx.say("result: ", result)
        }
    }
--- request
GET /t/shell.php
--- response_body
result: nil
--- error_log
all t1k servers failed
--- log_level: debug



=== TEST 4: do_access backward compatible with single host/port
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local t1k = require "resty.t1k"

            local t = {
                mode = "block",
                host = "127.0.0.1",
                port = 18000,
                connect_timeout = 1000,
                send_timeout = 1000,
                read_timeout = 1000,
                req_body_size = 1024,
                keepalive_size = 16,
                keepalive_timeout = 10000,
            }

            local ok, err, result = t1k.do_access(t)
            if not ok then
                ngx.log(ngx.ERR, err)
            end

            ngx.say(result["action"])
            ngx.say(result["status"])
        }
    }
--- tcp_listen: 18000
--- tcp_reply eval
"\x41\x01\x00\x00\x00?\x02\x03\x00\x00\x00405\xa4\x33\x00\x00\x00<!-- event_id: legacy_event -->"
--- request
GET /t/shell.php
--- response_body
?
405
--- no_error_log
[error]
--- error_log
successfully connected to t1k server 127.0.0.1:18000
--- log_level: debug



=== TEST 5: do_access with unix domain socket in servers array
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local t1k = require "resty.t1k"

            local t = {
                mode = "block",
                servers = {
                    { host = "unix:t1k.sock" },
                },
                connect_timeout = 1000,
                send_timeout = 1000,
                read_timeout = 1000,
                req_body_size = 1024,
                keepalive_size = 16,
                keepalive_timeout = 10000,
            }

            local ok, err, result = t1k.do_access(t)
            if not ok then
                ngx.log(ngx.ERR, err)
            end

            ngx.say(result["action"])
        }
    }
--- tcp_listen: t1k.sock
--- tcp_reply eval
"\xc1\x01\x00\x00\x00."
--- request
GET /t
--- response_body
.
--- no_error_log
[error]
--- error_log
successfully connected to t1k server unix:t1k.sock
--- log_level: debug



=== TEST 6: do_access with response_mode enabled
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local t1k = require "resty.t1k"

            local t = {
                mode = "block",
                host = "127.0.0.1",
                port = 18000,
                response_mode = "monitor",
                rsp_body_size = 4096,
                connect_timeout = 1000,
                send_timeout = 1000,
                read_timeout = 1000,
                req_body_size = 1024,
                keepalive_size = 16,
                keepalive_timeout = 10000,
            }

            local ok, err, result = t1k.do_access(t)
            if not ok then
                ngx.log(ngx.ERR, err)
            end

            ngx.say("ok: ", ok)
            ngx.say("response_mode: ", ngx.ctx.t1k_rsp_mode)
            ngx.say("has uuid: ", ngx.ctx.t1k_uuid and true or false)
            ngx.say("rsp_body_size: ", ngx.ctx.t1k_rsp_body_size)
        }
    }
--- tcp_listen: 18000
--- tcp_reply eval
"\xc1\x01\x00\x00\x00."
--- request
GET /t
--- response_body
ok: true
response_mode: monitor
has uuid: true
rsp_body_size: 4096
--- no_error_log
[error]
--- error_log
successfully connected to t1k server 127.0.0.1:18000
--- log_level: debug
