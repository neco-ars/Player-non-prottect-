#!/usr/bin/env python3
"""Прокси для веб-версии Music Player на своём сервере (VPS).

То же, что proxy/worker.js для Cloudflare, но работает на твоём сервере — например, в России,
откуда Звук не блокирует запросы (с серверов Cloudflare он отвечает 400/418/500).

Только стандартная библиотека Python 3.8+, без установки пакетов.
Слушает 127.0.0.1:8787; наружу его выпускает Caddy с HTTPS (см. install.sh).

Переменные окружения:
  ALLOWED_ORIGIN — адрес сайта, например https://nick.github.io (без пути и слеша на конце).
                   Если не задан — прокси отвечает всем сайтам (не рекомендуется).
  PORT           — порт (по умолчанию 8787).
"""
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# Куда можно ходить через прокси. Всё остальное — отказ: это не открытый прокси.
ALLOWED_HOSTS = [
    r"^soundcloud\.com$",
    r"^api-v2\.soundcloud\.com$",
    r"^a-v2\.sndcdn\.com$",  # скрипты сайта, оттуда берётся client_id
    r"^api\.audiomack\.com$",
    r"^zvuk\.com$",  # Звук: гостевой токен и GraphQL API
    r"^api\.genius\.com$",  # Genius: ссылка на страницу текста
    r"^api\.deezer\.com$",  # Deezer: похожие исполнители и радио для рекомендаций
]

# Какие заголовки клиента пересылаем дальше.
FORWARD_HEADERS = ["authorization", "x-auth-token", "accept", "accept-language", "content-type"]

BROWSER_UA = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/130.0 Safari/537.36"
)

ALLOWED_ORIGIN = os.environ.get("ALLOWED_ORIGIN", "").strip().rstrip("/")
MAX_BODY = 1024 * 1024  # запросы приложения маленькие; больше — значит что-то не то
TIMEOUT = 20


def host_allowed(host: str) -> bool:
    return any(re.match(p, host or "") for p in ALLOWED_HOSTS)


class Handler(BaseHTTPRequestHandler):
    server_version = "music-proxy"
    protocol_version = "HTTP/1.1"

    # --- общие части ---

    def cors_headers(self):
        return {
            "Access-Control-Allow-Origin": ALLOWED_ORIGIN or "*",
            "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
            "Access-Control-Allow-Headers": "Authorization, X-Auth-Token, Accept, Content-Type",
            "Access-Control-Max-Age": "86400",
            "Vary": "Origin",
        }

    def reply(self, status: int, body: bytes = b"", content_type: str = "text/plain; charset=utf-8", cors=True):
        self.send_response(status)
        if cors:
            for k, v in self.cors_headers().items():
                self.send_header(k, v)
        if body or status != 204:
            self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if body and self.command != "HEAD":
            self.wfile.write(body)

    def origin_ok(self) -> bool:
        if not ALLOWED_ORIGIN:
            return True
        return (self.headers.get("Origin") or "").rstrip("/") == ALLOWED_ORIGIN

    # --- запросы ---

    def do_OPTIONS(self):
        if not self.origin_ok():
            return self.reply(403, b"Forbidden origin", cors=False)
        self.reply(204)

    def do_GET(self):
        self.forward("GET")

    def do_POST(self):
        self.forward("POST")

    def forward(self, method: str):
        query = urllib.parse.urlparse(self.path).query
        raw = urllib.parse.parse_qs(query).get("url", [""])[0]
        # запрос без адреса — проверка «жив ли прокси»: отвечаем любому, ничего не пересылая
        if not raw:
            return self.reply(400, b"Bad url")
        if not self.origin_ok():
            return self.reply(403, b"Forbidden origin", cors=False)
        target = urllib.parse.urlparse(raw)
        if target.scheme != "https" or not host_allowed(target.hostname):
            return self.reply(403, b"Host not allowed")

        body = None
        if method == "POST":
            length = int(self.headers.get("Content-Length") or 0)
            if length > MAX_BODY:
                return self.reply(413, b"Too large")
            body = self.rfile.read(length) if length else b""

        headers = {"User-Agent": BROWSER_UA}
        for h in FORWARD_HEADERS:
            v = self.headers.get(h)
            if v:
                headers[h] = v
        if target.hostname == "zvuk.com":
            headers["Referer"] = "https://zvuk.com/"
            headers["Origin"] = "https://zvuk.com"

        req = urllib.request.Request(raw, data=body, headers=headers, method=method)
        try:
            resp = urllib.request.urlopen(req, timeout=TIMEOUT)
        except urllib.error.HTTPError as e:
            resp = e  # ответ сервиса с ошибкой (401, 404…) — передаём как есть
        except Exception as e:  # сеть, таймаут, DNS
            return self.reply(502, f"Upstream error: {e}".encode("utf-8"))

        with resp:
            data = resp.read()
            ctype = resp.headers.get("Content-Type", "application/octet-stream")
            self.reply(resp.status if hasattr(resp, "status") else resp.code, data, ctype)

    def log_message(self, fmt, *args):
        # без адресов запросов в логах: в них бывают токены
        sys.stderr.write("%s %s\n" % (self.command, args[1] if len(args) > 1 else ""))


def main():
    port = int(os.environ.get("PORT", "8787"))
    host = os.environ.get("HOST", "127.0.0.1")
    srv = ThreadingHTTPServer((host, port), Handler)
    print(f"music-proxy слушает {host}:{port}; ALLOWED_ORIGIN={ALLOWED_ORIGIN or '* (все сайты)'}", flush=True)
    srv.serve_forever()


if __name__ == "__main__":
    main()
