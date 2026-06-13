use Test::Nginx::Socket;

our $HttpConfig = <<'_EOC_';
    lua_package_path "lib/?.lua;/usr/local/share/lua/5.1/?.lua;;";
_EOC_

repeat_each(3);

plan tests => repeat_each() * (blocks() * 3);

run_tests();

__DATA__

=== TEST 1: server_pool new with single server
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local server_pool = require "resty.t1k.server_pool"
            local pool, err = server_pool.new({
                { host = "127.0.0.1", port = 8000 }
            })
            if not pool then
                ngx.say("error: ", err)
            else
                ngx.say("servers: ", #pool.servers)
                local srv = server_pool.select(pool)
                ngx.say("selected host: ", srv.host)
                ngx.say("selected port: ", srv.port)
            end
        }
    }
--- request
GET /t
--- response_body
servers: 1
selected host: 127.0.0.1
selected port: 8000
--- no_error_log
[error]



=== TEST 2: server_pool new with multiple servers
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local server_pool = require "resty.t1k.server_pool"
            local pool, err = server_pool.new({
                { host = "127.0.0.1", port = 8000 },
                { host = "127.0.0.1", port = 8001 },
                { host = "unix:/tmp/detector.sock" }
            })
            if not pool then
                ngx.say("error: ", err)
            else
                ngx.say("servers: ", #pool.servers)
                local srv1 = server_pool.select(pool)
                ngx.say("first host: ", srv1.host)
                local srv2 = server_pool.select(pool)
                ngx.say("second host: ", srv2.host)
            end
        }
    }
--- request
GET /t
--- response_body
servers: 3
first host: 127.0.0.1
second host: 127.0.0.1
--- no_error_log
[error]



=== TEST 3: server_pool new with empty servers
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local server_pool = require "resty.t1k.server_pool"
            local pool, err = server_pool.new({})
            if not pool then
                ngx.say("error: ", err)
            else
                ngx.say("ok")
            end
        }
    }
--- request
GET /t
--- response_body
error: no servers configured
--- no_error_log
[error]



=== TEST 4: server_pool new with missing host
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local server_pool = require "resty.t1k.server_pool"
            local pool, err = server_pool.new({
                { port = 8000 }
            })
            if not pool then
                ngx.say("error: ", err)
            else
                ngx.say("ok")
            end
        }
    }
--- request
GET /t
--- response_body
error: server 1 missing host
--- no_error_log
[error]



=== TEST 5: server_pool mark_failed and health
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local server_pool = require "resty.t1k.server_pool"
            local pool = server_pool.new({
                { host = "127.0.0.1", port = 8000, max_fails = 2 },
                { host = "127.0.0.1", port = 8001 }
            })
            local srv = pool.servers[1]
            ngx.say("initially healthy: ", server_pool.is_healthy(srv))
            server_pool.mark_failed(srv)
            ngx.say("after 1 fail: ", server_pool.is_healthy(srv))
            server_pool.mark_failed(srv)
            ngx.say("after 2 fails: ", server_pool.is_healthy(srv))
        }
    }
--- request
GET /t
--- response_body
initially healthy: true
after 1 fail: true
after 2 fails: false
--- no_error_log
[error]



=== TEST 6: server_pool select_all_healthy
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local server_pool = require "resty.t1k.server_pool"
            local pool = server_pool.new({
                { host = "127.0.0.1", port = 8000, max_fails = 1 },
                { host = "127.0.0.1", port = 8001 }
            })
            server_pool.mark_failed(pool.servers[1])
            local healthy = server_pool.select_all_healthy(pool)
            ngx.say("healthy count: ", #healthy)
            ngx.say("healthy host: ", healthy[1].host)
        }
    }
--- request
GET /t
--- response_body
healthy count: 1
healthy host: 127.0.0.1
--- no_error_log
[error]



=== TEST 7: server_pool server_key
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local server_pool = require "resty.t1k.server_pool"
            local pool = server_pool.new({
                { host = "127.0.0.1", port = 8000 },
                { host = "unix:/tmp/detector.sock" }
            })
            ngx.say("tcp key: ", server_pool.server_key(pool.servers[1]))
            ngx.say("uds key: ", server_pool.server_key(pool.servers[2]))
        }
    }
--- request
GET /t
--- response_body
tcp key: 127.0.0.1:8000
uds key: unix:/tmp/detector.sock
--- no_error_log
[error]
