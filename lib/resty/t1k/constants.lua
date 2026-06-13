local t = {}

t.ACTION_PASSED = "."
t.ACTION_BLOCKED = "?"

t.MODE_OFF = "off"
t.MODE_BLOCK = "block"
t.MODE_MONITOR = "monitor"

t.T1K_HEADER_SIZE = 5

t.TAG_HEAD = 0x01
t.TAG_BODY = 0x02
t.TAG_EXTRA = 0x03

t.TAG_RSP_HEAD = 0x11
t.TAG_RSP_BODY = 0x12
t.TAG_RSP_EXTRA = 0x13

t.TAG_VERSION = 0x20
t.TAG_ALOG = 0x21
t.TAG_STAT = 0x22
t.TAG_EXTRA_HEADER = 0x23
t.TAG_EXTRA_BODY = 0x24
t.TAG_CONTEXT = 0x25

t.MASK_FIRST = 0x40
t.MASK_LAST = 0x80

t.NGX_HTTP_HEADER_PREFIX = "http_"

t.BLOCK_CONTENT_TYPE = "application/json"
t.BLOCK_CONTENT_FORMAT = [[
{"code": %s, "success":false, "message": "blocked by Chaitin SafeLine Web Application Firewall", "event_id": "%s"}]]

t.UNIX_SOCK_PREFIX = "unix:"

t.KEY_EXTRA_UUID = "UUID"
t.KEY_EXTRA_REMOTE_ADDR = "RemoteAddr"
t.KEY_EXTRA_REMOTE_PORT = "RemotePort"
t.KEY_EXTRA_LOCAL_ADDR = "LocalAddr"
t.KEY_EXTRA_LOCAL_PORT = "LocalPort"
t.KEY_EXTRA_SCHEME = "Scheme"
t.KEY_EXTRA_SERVER_NAME = "ServerName"
t.KEY_EXTRA_PROXY_NAME = "ProxyName"
t.KEY_EXTRA_REQ_BEGIN_TIME = "ReqBeginTime"
t.KEY_EXTRA_REQ_END_TIME = "ReqEndTime"
t.KEY_EXTRA_RSP_BEGIN_TIME = "RspBeginTime"
t.KEY_EXTRA_RSP_END_TIME = "RspEndTime"
t.KEY_EXTRA_UPSTREAM_ADDR = "UpstreamAddr"
t.KEY_EXTRA_HAS_RSP_IF_OK = "HasRspIfOK"
t.KEY_EXTRA_HAS_RSP_IF_BLOCK = "HasRspIfBlock"

return t
