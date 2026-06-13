use Test::Nginx::Socket;

our $HttpConfig = <<'_EOC_';
    lua_package_path "lib/?.lua;/usr/local/share/lua/5.1/?.lua;;";
_EOC_

repeat_each(3);

plan tests => repeat_each() * (blocks() * 3);

run_tests();

__DATA__

=== TEST 1: response detection with mock detector - pass
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local response = require "resty.t1k.response"
            local consts = require "resty.t1k.constants"

            -- Simulate request context
            local ctx = {
                t1k_uuid = "test-uuid-123",
                t1k_rsp_begin_time = 1234567890,
                t1k_context = "",
                t1k_raw_request_header = "GET /test HTTP/1.1\r\nHost: localhost\r\n\r\n",
                t1k_rsp_body = "response body content",
            }

            local opts = {
                host = "127.0.0.1",
                port = 18000,
                connect_timeout = 1000,
                send_timeout = 1000,
                read_timeout = 1000,
                keepalive_size = 16,
                keepalive_timeout = 10000,
            }

            local ok, err, result = response.do_response_detect(opts, ctx)
            if not ok then
                ngx.say("error: ", err)
            else
                ngx.say("action: ", result.action)
            end
        }
    }
--- tcp_listen: 18000
--- tcp_reply eval
"\xc1\x01\x00\x00\x00."
--- request
GET /t
--- response_body
action: .
--- no_error_log
[error]
--- error_log
successfully connected to t1k server 127.0.0.1:18000 for response detection
--- log_level: debug



=== TEST 2: response detection with mock detector - block
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local response = require "resty.t1k.response"
            local consts = require "resty.t1k.constants"

            local ctx = {
                t1k_uuid = "test-uuid-456",
                t1k_rsp_begin_time = 1234567890,
                t1k_context = "",
                t1k_raw_request_header = "GET /test HTTP/1.1\r\nHost: localhost\r\n\r\n",
                t1k_rsp_body = "malicious response",
            }

            local opts = {
                host = "127.0.0.1",
                port = 18000,
                connect_timeout = 1000,
                send_timeout = 1000,
                read_timeout = 1000,
                keepalive_size = 16,
                keepalive_timeout = 10000,
            }

            local ok, err, result = response.do_response_detect(opts, ctx)
            if not ok then
                ngx.say("error: ", err)
            else
                ngx.say("action: ", result.action)
            end
        }
    }
--- tcp_listen: 18000
--- tcp_reply eval
"\x41\x01\x00\x00\x00?\x02\x03\x00\x00\x00405\xa4\x33\x00\x00\x00<!-- event_id: c0c039a7c348486eaffd9e2f9846b66b -->"
--- request
GET /t
--- response_body
action: ?
--- no_error_log
[error]
--- error_log
successfully connected to t1k server 127.0.0.1:18000 for response detection
--- log_level: debug



=== TEST 3: response detection connection refuse
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local response = require "resty.t1k.response"

            local ctx = {
                t1k_uuid = "test-uuid-789",
                t1k_context = "",
                t1k_raw_request_header = "GET /test HTTP/1.1\r\nHost: localhost\r\n\r\n",
            }

            local opts = {
                host = "127.0.0.1",
                port = 18000,
                connect_timeout = 100,
                send_timeout = 100,
                read_timeout = 100,
                keepalive_size = 16,
                keepalive_timeout = 10000,
            }

            local ok, err, result = response.do_response_detect(opts, ctx)
            ngx.say("ok: ", ok)
        }
    }
--- request
GET /t
--- response_body
ok: nil
--- error_log
failed to connect to t1k server 127.0.0.1:18000
--- log_level: debug
