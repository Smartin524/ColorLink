#!/usr/bin/env python3
"""
模拟手机端：实现与安卓 App 相同的协议（见 PROTOCOL.md），没有手机时用来调试 Mac 端。

用法：
  python3 mock_phone.py --code 123456                 # 默认用系统自带的壁纸、视频、提示音当“手机相册”
  python3 mock_phone.py --code 123456 --dir ~/Pictures

另开一个终端模拟手机上发生的事：
  curl -X POST localhost:8765/debug/screenshot
  curl -X POST localhost:8765/debug/notify          # 默认发一条验证码短信
  curl -X POST 'localhost:8765/debug/clipboard?text=hello'
  curl -X POST localhost:8765/debug/knock
  curl -X POST 'localhost:8765/debug/power?charging=1'   # 模拟插上电源（0 = 拔掉）
  curl -X POST 'localhost:8765/debug/dnd?mode=priority'  # 模拟手机上手动改免打扰（all/priority/alarms/none）

模拟“锁屏后 mDNS 收不到”：加 --no-mdns，此时 Mac 只能靠敲门或上次的地址找到手机。

只用 Python 标准库；缩略图用 macOS 自带的 sips / qlmanage 生成。
"""

import argparse
import atexit
import hashlib
import hmac
import json
import mimetypes
import os
import queue
import random
import secrets
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, quote, urlparse

IMAGE_EXT = {".jpg", ".jpeg", ".png", ".heic", ".gif", ".webp"}
VIDEO_EXT = {".mov", ".mp4", ".m4v"}
AUDIO_EXT = {".m4a", ".mp3", ".wav", ".aac", ".aiff", ".caf"}
EXTRA_MIME = {".heic": "image/heic", ".aiff": "audio/aiff", ".caf": "audio/x-caf", ".m4a": "audio/mp4"}

DEFAULT_DIRS = ["/System/Library/Desktop Pictures", "/System/Library/Sounds"]

DEVICE_ID = "mock-oppo-0001"
DEVICE_NAME = "OPPO Find X8（模拟）"
BATTERY = None
DOZE = False


def kind_of(path):
    ext = os.path.splitext(path)[1].lower()
    if ext in IMAGE_EXT:
        return "image"
    if ext in VIDEO_EXT:
        return "video"
    if ext in AUDIO_EXT:
        return "audio"
    return None


class Library:
    """模拟 MediaStore：扫描目录，分配 id，按加入时间倒序。"""

    def __init__(self, dirs, cache_dir):
        self.lock = threading.Lock()
        self.items = {"image": [], "video": [], "audio": []}
        self.paths = {}
        self.next_id = 1
        self.cache_dir = cache_dir
        self.thumb_slots = threading.Semaphore(4)
        self.thumb_locks = {}
        for d in dirs:
            for root, _, files in os.walk(os.path.expanduser(d)):
                for f in files:
                    p = os.path.join(root, f)
                    if kind_of(p):
                        self.add(p, sort=False)
        for lst in self.items.values():
            lst.sort(key=lambda it: it["added"], reverse=True)

    def add(self, path, sort=True, added=None):
        kind = kind_of(path)
        st = os.stat(path)
        ext = os.path.splitext(path)[1].lower()
        with self.lock:
            item = {
                "id": self.next_id,
                "kind": kind,
                "name": os.path.basename(path),
                "mime": EXTRA_MIME.get(ext) or mimetypes.guess_type(path)[0] or "application/octet-stream",
                "size": st.st_size,
                "modified": int(st.st_mtime),
                "added": int(added or st.st_mtime),
                "width": None,
                "height": None,
                "duration": None,
                "path": os.path.basename(os.path.dirname(path)) + "/",
            }
            self.next_id += 1
            self.paths[item["id"]] = path
            self.items[kind].insert(0, item)
            if sort:
                self.items[kind].sort(key=lambda it: it["added"], reverse=True)
        return item

    def page(self, kind, offset, limit):
        with self.lock:
            lst = self.items[kind]
            return {"total": len(lst), "items": lst[offset:offset + limit]}

    def get(self, kind, item_id):
        with self.lock:
            for it in self.items.get(kind, []):
                if it["id"] == item_id:
                    return it, self.paths[item_id]
        return None, None

    def thumbnail(self, kind, item_id, size):
        """和安卓端一样：先查磁盘缓存，没有才生成，同一张图不会同时生成两次。"""
        item, path = self.get(kind, item_id)
        if not item or kind == "audio":
            return None
        out = os.path.join(self.cache_dir, f"{kind}_{item_id}_{item['modified']}_{size}.jpg")
        if os.path.exists(out):
            with open(out, "rb") as f:
                return f.read()
        with self.lock:
            lk = self.thumb_locks.setdefault(out, threading.Lock())
        with lk, self.thumb_slots:
            if not os.path.exists(out):
                tmp = out + ".tmp.jpg"
                if kind == "image":
                    src = path
                else:
                    # 视频先用 Quick Look 截一帧
                    qdir = tempfile.mkdtemp(dir=self.cache_dir)
                    subprocess.run(["qlmanage", "-t", "-s", str(size * 2), "-o", qdir, path],
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                    pngs = [f for f in os.listdir(qdir) if f.endswith(".png")]
                    if not pngs:
                        shutil.rmtree(qdir, ignore_errors=True)
                        return None
                    src = os.path.join(qdir, pngs[0])
                r = subprocess.run(["sips", "-s", "format", "jpeg", "-s", "formatOptions", "80",
                                    "-Z", str(size), src, "--out", tmp],
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                if kind == "video":
                    shutil.rmtree(os.path.dirname(src), ignore_errors=True)
                if r.returncode != 0 or not os.path.exists(tmp):
                    return None
                os.replace(tmp, out)
        with open(out, "rb") as f:
            return f.read()

    def prewarm(self, n=200):
        """模拟手机充电时预生成缩略图。"""
        t = time.time()
        done = 0
        for kind in ("image", "video"):
            for it in self.page(kind, 0, n)["items"]:
                if self.thumbnail(kind, it["id"], 256):
                    done += 1
        print(f"[mock] 预生成缩略图完成：{done} 张，用时 {time.time() - t:.1f}s", flush=True)


class EventBus:
    def __init__(self):
        self.lock = threading.Lock()
        self.subs = []

    def subscribe(self):
        q = queue.Queue(maxsize=256)
        with self.lock:
            self.subs.append(q)
        print(f"[mock] Mac 已连接事件流（共 {len(self.subs)} 个）", flush=True)
        return q

    def unsubscribe(self, q):
        with self.lock:
            if q in self.subs:
                self.subs.remove(q)
        print(f"[mock] Mac 断开事件流（剩 {len(self.subs)} 个）", flush=True)

    def ping(self):
        with self.lock:
            for q in self.subs:
                try:
                    q.put_nowait(": ping\n\n")
                except queue.Full:
                    pass

    def publish(self, event, data):
        msg = f"event: {event}\ndata: {json.dumps(data, ensure_ascii=False, separators=(',', ':'))}\n\n"
        with self.lock:
            for q in self.subs:
                try:
                    q.put_nowait(msg)
                except queue.Full:
                    pass


class State:
    def __init__(self, code, library, data_dir):
        self.code = code
        # 和真手机一样持久保存令牌，否则模拟器一重启，Mac 就会当作被取消配对
        token_file = os.path.join(data_dir, "token")
        if os.path.exists(token_file):
            with open(token_file) as f:
                self.token = f.read().strip()
        else:
            self.token = secrets.token_hex(32)
            with open(token_file, "w") as f:
                f.write(self.token)
        self.library = library
        self.bus = EventBus()
        self.data_dir = data_dir
        self.failed_pairs = 0
        self.lock = threading.Lock()
        self.mac_name = "Mac"
        self.port = 8765
        self.charging = False
        self.dnd = "all"

    def info(self):
        return {"deviceId": DEVICE_ID, "name": DEVICE_NAME, "model": "PHZ110", "android": "15",
                "battery": BATTERY or random.randint(40, 95), "charging": self.charging, "dnd": self.dnd}


STATE = None


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"  # keep-alive，和手机端一致
    server_version = "ColorLinkMock/0.1"

    def log_message(self, fmt, *args):
        if os.environ.get("MOCK_VERBOSE"):
            super().log_message(fmt, *args)

    def do_GET(self):
        self.route(head=False)

    def do_HEAD(self):
        self.route(head=True)

    def do_POST(self):
        # 上传接口自己读请求体，其他 POST 的请求体直接丢掉
        if not self.path.startswith("/api/upload"):
            n = int(self.headers.get("Content-Length") or 0)
            if n:
                self.rfile.read(n)
        self.route(head=False)

    # ---- 工具 ----

    def send_bytes(self, status, data, ctype, extra=None, head=False):
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        if not head:
            self.wfile.write(data)

    def send_json(self, obj, status=200):
        self.send_bytes(status, json.dumps(obj, ensure_ascii=False).encode(), "application/json; charset=utf-8")

    def send_text(self, status, text):
        self.send_bytes(status, text.encode(), "text/plain; charset=utf-8")

    def authorized(self, q):
        auth = self.headers.get("Authorization", "")
        given = auth[len("Bearer "):].strip() if auth.startswith("Bearer ") else q.get("t", "")
        return bool(given) and hmac.compare_digest(given, STATE.token)

    # ---- 路由 ----

    def route(self, head):
        # http.server 按 Latin-1 解码请求行；curl 直接发中文时要还原成 UTF-8
        try:
            raw = self.path.encode("iso-8859-1").decode("utf-8")
        except UnicodeError:
            raw = self.path
        u = urlparse(raw)
        q = {k: v[0] for k, v in parse_qs(u.query).items()}
        path = u.path

        if path == "/api/pair":
            return self.pair(q)
        if path == "/api/id":
            return self.send_json({"deviceId": DEVICE_ID, "name": DEVICE_NAME})
        if path.startswith("/debug/"):
            if self.client_address[0] not in ("127.0.0.1", "::1"):
                return self.send_text(403, "debug only from localhost")
            return self.debug(path, q)
        if not self.authorized(q):
            return self.send_text(401, "unauthorized")

        if path == "/api/info":
            STATE.bus.ping()
            return self.send_json(STATE.info())
        if path == "/api/media":
            kind = q.get("kind")
            if kind not in ("image", "video", "audio"):
                return self.send_text(400, "bad kind")
            offset = max(0, int(q.get("offset", 0)))
            limit = min(500, max(1, int(q.get("limit", 200))))
            return self.send_json(STATE.library.page(kind, offset, limit))
        if path == "/api/thumb":
            data = STATE.library.thumbnail(q.get("kind"), int(q.get("id", 0)), int(q.get("size", 256)))
            if data is None:
                return self.send_text(404, "no thumbnail")
            return self.send_bytes(200, data, "image/jpeg", {"Cache-Control": "max-age=31536000, immutable"}, head)
        if path == "/api/file":
            return self.file(q, head)
        if path == "/api/events":
            if q.get("name"):
                STATE.mac_name = q["name"]
            return self.events()
        if path == "/api/upload":
            return self.upload(q)
        if path == "/api/dnd":
            if self.command == "POST":
                mode = q.get("mode")
                if mode not in ("all", "priority", "alarms", "none"):
                    return self.send_text(400, "bad mode")
                STATE.dnd = mode
                # 真手机是系统改完再回调；这里直接推事件
                STATE.bus.publish("dnd", {"mode": mode})
                print(f"[mock] Mac 把免打扰改为 {mode}", flush=True)
            return self.send_json({"mode": STATE.dnd})
        return self.send_text(404, "not found")

    def pair(self, q):
        with STATE.lock:
            if not hmac.compare_digest(q.get("code", ""), STATE.code):
                STATE.failed_pairs += 1
                return self.send_text(403, "wrong code")
            STATE.failed_pairs = 0
            print(f"[mock] 「{q.get('client', '?')}」配对成功", flush=True)
            return self.send_json({"token": STATE.token, "deviceId": DEVICE_ID, "name": DEVICE_NAME})

    def file(self, q, head):
        item, path = STATE.library.get(q.get("kind"), int(q.get("id", 0)))
        if not item:
            return self.send_text(404, "not found")
        size = os.path.getsize(path)
        headers = {"Accept-Ranges": "bytes",
                   "Content-Disposition": "inline; filename*=UTF-8''" + quote(item["name"])}
        start, end, status = 0, size - 1, 200
        rng = self.headers.get("Range")
        if rng and rng.startswith("bytes=") and size > 0:
            spec = rng[6:].split(",")[0].strip()
            s, _, e = spec.partition("-")
            if s == "":
                start, end = max(0, size - int(e or 0)), size - 1
            else:
                start, end = int(s), min(int(e), size - 1) if e else size - 1
            if start > end or start >= size:
                return self.send_bytes(416, b"", "text/plain", {"Content-Range": f"bytes */{size}"})
            status = 206
            headers["Content-Range"] = f"bytes {start}-{end}/{size}"
        length = end - start + 1
        self.send_response(status)
        self.send_header("Content-Type", item["mime"])
        self.send_header("Content-Length", str(length))
        for k, v in headers.items():
            self.send_header(k, v)
        self.end_headers()
        if head:
            return
        try:
            with open(path, "rb") as f:
                f.seek(start)
                left = length
                while left > 0:
                    chunk = f.read(min(64 * 1024, left))
                    if not chunk:
                        break
                    self.wfile.write(chunk)
                    left -= len(chunk)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def upload(self, q):
        """和手机一样：图片进相册（这里是 received/ 目录并加入模拟相册），其他文件只保存。"""
        if self.command != "POST":
            return self.send_text(405, "use POST")
        n = int(self.headers.get("Content-Length") or 0)
        name = os.path.basename(q.get("name") or "file") or "file"
        mime = q.get("mime") or mimetypes.guess_type(name)[0] or "application/octet-stream"
        folder = os.path.join(STATE.data_dir, "received")
        os.makedirs(folder, exist_ok=True)
        base, ext = os.path.splitext(name)
        dest, i = os.path.join(folder, name), 2
        while os.path.exists(dest):
            dest, i = os.path.join(folder, f"{base} {i}{ext}"), i + 1
        left = n
        with open(dest, "wb") as f:
            while left > 0:
                chunk = self.rfile.read(min(64 * 1024, left))
                if not chunk:
                    break
                f.write(chunk)
                left -= len(chunk)
        print(f"[mock] 收到「{STATE.mac_name}」发来的 {os.path.basename(dest)}（{n // 1024} KB，{mime}）", flush=True)
        if kind_of(dest) == "image":
            item = STATE.library.add(dest, added=time.time())
            STATE.bus.publish("media", item)  # 和手机一样：新照片会通知 Mac 刷新最近照片
            return self.send_json(item)
        return self.send_json({"name": os.path.basename(dest), "mime": mime, "path": "Download/ColorLink/"})

    def events(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream; charset=utf-8")
        self.send_header("Cache-Control", "no-cache")
        # 没有这个头，macOS 的 URLSession 会先攒够 512 字节用来猜内容类型，事件就迟迟收不到
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Connection", "close")
        self.end_headers()
        self.close_connection = True
        # 和手机一样记下 Mac 的地址，下次启动时给它敲门
        with open(os.path.join(STATE.data_dir, "last_mac"), "w") as f:
            f.write(self.client_address[0])
        q = STATE.bus.subscribe()
        try:
            hello = json.dumps(STATE.info(), ensure_ascii=False, separators=(",", ":"))
            self.wfile.write(f"event: hello\ndata: {hello}\n\n".encode())
            self.wfile.flush()
            while True:
                try:
                    # 模拟手机深睡：CPU 停着，20 秒的 ping 计时不走，只有事件（包括 /api/info 推的 ping）才会写出
                    msg = q.get(timeout=None if DOZE else 20)
                except queue.Empty:
                    msg = ": ping\n\n"
                self.wfile.write(msg.encode())
                self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError, OSError):
            pass
        finally:
            STATE.bus.unsubscribe(q)

    def debug(self, path, q):
        if path == "/debug/screenshot":
            item = make_screenshot()
            if not item:
                return self.send_text(500, "没有可用的图片来生成截图")
            STATE.bus.publish("screenshot", item)
            print(f"[mock] 模拟截图 {item['name']}，已推送", flush=True)
            return self.send_json(item)
        if path == "/debug/notify":
            # 默认是一条验证码短信；?pkg=com.xxx&app=xxx 可以模拟别的 App 的通知（那时 Mac 不找验证码）
            code = f"{random.randint(0, 999999):06d}"
            pkg = q.get("pkg", "com.android.mms")
            n = {"key": secrets.token_hex(4), "pkg": pkg, "app": q.get("app", "信息"),
                 "sms": pkg == "com.android.mms",
                 "title": q.get("title", "106905993"),
                 "text": q.get("text", f"【ColorLink】您的验证码为 {code}，5分钟内有效，请勿泄露。"),
                 "time": int(time.time() * 1000)}
            STATE.bus.publish("notification", n)
            return self.send_json(n)
        if path == "/debug/knock":
            return self.send_json({"sent": knock(STATE.port)})
        if path == "/debug/clipboard":
            STATE.bus.publish("clipboard", {"text": q.get("text", "")})
            return self.send_json({"ok": True})
        if path == "/debug/dnd":
            STATE.dnd = q.get("mode", "priority")
            STATE.bus.publish("dnd", {"mode": STATE.dnd})
            return self.send_json({"mode": STATE.dnd})
        if path == "/debug/power":
            # 模拟插拔电源：?charging=1 插上，?charging=0 拔掉。Mac 据此开始 / 停止后台补缩略图
            STATE.charging = q.get("charging", "1") == "1"
            event = {"charging": STATE.charging, "battery": STATE.info()["battery"]}
            STATE.bus.publish("power", event)
            print(f"[mock] 模拟{'插上' if STATE.charging else '拔掉'}电源，已推送", flush=True)
            return self.send_json(event)
        return self.send_text(404, "unknown debug command")


KNOCK_PORT = 8766


def knock(http_port):
    """手机主动敲门：给上次连过的 Mac 和本网段广播各发一个带签名的 UDP 包。"""
    ts = int(time.time())
    sig = hmac.new(STATE.token.encode(), f"{DEVICE_ID}|{http_port}|{ts}".encode(), hashlib.sha256).hexdigest()
    payload = json.dumps({"v": 1, "id": DEVICE_ID, "port": http_port, "ts": ts, "sig": sig}).encode()
    targets = []
    last = os.path.join(STATE.data_dir, "last_mac")
    if os.path.exists(last):
        with open(last) as f:
            targets.append(f.read().strip())
    targets.append("255.255.255.255")
    sent = []
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
        s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
        for t in targets:
            try:
                s.sendto(payload, (t, KNOCK_PORT))
                sent.append(t)
            except OSError:
                pass
    print(f"[mock] 已敲门：{', '.join(sent) or '无目标'}", flush=True)
    return sent


def knock_on_start(http_port):
    # 与安卓端一致：立即、3 秒、10 秒各敲一次，已有 Mac 连上就停
    for delay in (0, 3, 7):
        time.sleep(delay)
        if STATE.bus.subs:
            return
        knock(http_port)


def make_screenshot():
    """拿相册里任意一张图转成 PNG，当作刚截的屏。"""
    images = STATE.library.page("image", 0, 1000)["items"]
    if not images:
        return None
    src = STATE.library.paths[random.choice(images)["id"]]
    shots = os.path.join(STATE.data_dir, "Screenshots")
    os.makedirs(shots, exist_ok=True)
    name = time.strftime("Screenshot_%Y-%m-%d-%H-%M-%S") + f"-{random.randint(10, 99)}.png"
    out = os.path.join(shots, name)
    subprocess.run(["sips", "-s", "format", "png", "-Z", "1600", src, "--out", out],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if not os.path.exists(out):
        return None
    return STATE.library.add(out, added=time.time())


def main():
    global STATE
    ap = argparse.ArgumentParser(description="ColorLink 模拟手机")
    ap.add_argument("--port", type=int, default=8765)
    ap.add_argument("--code", default=None, help="配对码，默认随机生成")
    ap.add_argument("--dir", action="append", help="当作手机相册的目录，可写多次")
    ap.add_argument("--data", default=os.path.join(tempfile.gettempdir(), "colorlink-mock"),
                    help="缩略图缓存与模拟截图存放目录")
    ap.add_argument("--no-mdns", action="store_true", help="不广播 mDNS（只能手动输入地址连接）")
    ap.add_argument("--no-knock", action="store_true", help="启动时不敲门（用来对比有无敲门的重连速度）")
    ap.add_argument("--no-prewarm", action="store_true", help="不预生成缩略图（用来测冷启动）")
    ap.add_argument("--name", help="手机名称（录演示视频时用真实型号）")
    ap.add_argument("--battery", type=int, help="固定电量（默认随机）")
    ap.add_argument("--doze", action="store_true", help="模拟手机深睡：事件流不发定时 ping，只在收到 /api/info 时回一行")
    args = ap.parse_args()
    global DEVICE_NAME, BATTERY, DOZE
    if args.name:
        DEVICE_NAME = args.name
    BATTERY = args.battery
    DOZE = args.doze

    os.makedirs(os.path.join(args.data, "thumbs"), exist_ok=True)
    lib = Library(args.dir or DEFAULT_DIRS, os.path.join(args.data, "thumbs"))
    STATE = State(args.code or f"{secrets.randbelow(1_000_000):06d}", lib, args.data)
    STATE.port = args.port

    server = ThreadingHTTPServer(("0.0.0.0", args.port), Handler)
    server.daemon_threads = True

    if not args.no_mdns:
        # macOS 自带 dns-sd，用它代替安卓的 NsdManager 广播服务
        p = subprocess.Popen(["dns-sd", "-R", "ColorLink-Mock", "_colorlink._tcp", "local", str(args.port),
                              f"id={DEVICE_ID}", "name=Mock"],
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        atexit.register(p.terminate)
        # 被 kill 时也要撤掉 mDNS 广播，否则 Mac 会一直看到一个已经不存在的“手机”
        signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))

    counts = {k: len(v) for k, v in lib.items.items()}
    print(f"[mock] 模拟手机已启动：端口 {args.port}，配对码 {STATE.code}", flush=True)
    print(f"[mock] 相册：照片 {counts['image']}，视频 {counts['video']}，录音 {counts['audio']}", flush=True)
    if not args.no_knock:
        threading.Thread(target=knock_on_start, args=(args.port,), daemon=True).start()
    if not args.no_prewarm:
        threading.Thread(target=lib.prewarm, daemon=True).start()
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
