"""
opencodex LAN Share - 认证转发代理
在 opencodex 前面加一层，把标准的 Authorization: Bearer 转成 x-opencodex-api-key

用法: python auth-proxy.py [--port 10101] [--target http://127.0.0.1:10100]
"""
import http.server
import urllib.request
import urllib.error
import json
import sys
import os
import argparse
import logging

logging.basicConfig(level=logging.INFO, format='[%(asctime)s] %(message)s', datefmt='%H:%M:%S')
log = logging.getLogger('auth-proxy')

# 从 opencodex config 读取有效的 access keys
def load_valid_keys():
    config_path = os.path.expanduser("~/.opencodex/config.json")
    keys = set()
    try:
        with open(config_path) as f:
            config = json.load(f)
        for entry in config.get("apiKeys", []):
            if "key" in entry and entry["key"].strip():
                keys.add(entry["key"].strip())
        log.info(f"Loaded {len(keys)} valid access key(s)")
    except Exception as e:
        log.error(f"Failed to load keys: {e}")
    return keys

VALID_KEYS = set()

class AuthProxy(http.server.ThreadingHTTPServer):
    allow_reuse_address = True
    daemon_threads = True

class ProxyHandler(http.server.BaseHTTPRequestHandler):
    target_host = "127.0.0.1"
    target_port = 10100

    def do_request(self, method):
        global VALID_KEYS

        # 提取客户端的 Authorization: Bearer <key>
        auth_header = self.headers.get("Authorization", "")
        client_key = ""
        if auth_header.startswith("Bearer "):
            client_key = auth_header[7:].strip()

        # 验证 key
        if not client_key or client_key not in VALID_KEYS:
            self.send_error(401, "Invalid or missing API key")
            return

        # 构建转发请求
        target_url = f"http://{self.target_host}:{self.target_port}{self.path}"

        body = None
        content_length = self.headers.get("Content-Length")
        if content_length:
            body = self.rfile.read(int(content_length))

        req = urllib.request.Request(target_url, data=body, method=method)

        # 复制请求头，但替换认证头
        for key, value in self.headers.items():
            if key.lower() in ("host", "authorization", "content-length"):
                continue
            req.add_header(key, value)

        # 用 x-opencodex-api-key 替换 Authorization
        req.add_header("x-opencodex-api-key", client_key)
        # 确保 opencodex 也看到 Authorization（有些路由需要）
        req.add_header("Authorization", f"Bearer {client_key}")

        # 转发并返回响应
        try:
            with urllib.request.urlopen(req, timeout=120) as resp:
                self.send_response(resp.status)
                # 复制响应头（跳过 transfer-encoding）
                for key, value in resp.headers.items():
                    if key.lower() in ("transfer-encoding", "connection"):
                        continue
                    self.send_header(key, value)
                self.end_headers()

                # 流式转发响应体
                while True:
                    chunk = resp.read(8192)
                    if not chunk:
                        break
                    self.wfile.write(chunk)
                    self.wfile.flush()

        except urllib.error.HTTPError as e:
            self.send_response(e.code)
            self.end_headers()
            error_body = e.read()
            self.wfile.write(error_body)

        except Exception as e:
            log.error(f"Proxy error: {e}")
            self.send_error(502, f"Proxy error: {e}")

    def do_GET(self):    self.do_request("GET")
    def do_POST(self):   self.do_request("POST")
    def do_PUT(self):    self.do_request("PUT")
    def do_DELETE(self): self.do_request("DELETE")
    def do_PATCH(self):  self.do_request("PATCH")
    def do_OPTIONS(self):
        self.send_response(200)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Authorization, Content-Type, x-opencodex-api-key")
        self.end_headers()

    def log_message(self, format, *args):
        log.info(f"{self.client_address[0]} - {format % args}")


def main():
    parser = argparse.ArgumentParser(description="opencodex Auth Proxy")
    parser.add_argument("--port", type=int, default=10101)
    parser.add_argument("--target", type=str, default="http://127.0.0.1:10100")
    args = parser.parse_args()

    global VALID_KEYS
    VALID_KEYS = load_valid_keys()

    # 从 target URL 解析 host/port
    target = args.target.replace("http://", "").replace("https://", "")
    if ":" in target:
        ProxyHandler.target_host, port_str = target.split(":", 1)
        ProxyHandler.target_port = int(port_str)
    else:
        ProxyHandler.target_host = target

    server = AuthProxy(("0.0.0.0", args.port), ProxyHandler)
    log.info(f"Auth proxy listening on 0.0.0.0:{args.port} -> {args.target}")
    log.info(f"Valid keys loaded: {len(VALID_KEYS)}")

    # 定期刷新 key 列表（每 60 秒）
    import threading
    def refresh_keys():
        global VALID_KEYS
        while True:
            import time
            time.sleep(60)
            VALID_KEYS = load_valid_keys()
    threading.Thread(target=refresh_keys, daemon=True).start()

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        log.info("Shutting down...")
        server.shutdown()


if __name__ == "__main__":
    main()
