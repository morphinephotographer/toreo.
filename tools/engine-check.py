"""Exercise the bundled bridge with an isolated swarm on this Mac."""
import base64
import ctypes
import hashlib
import http.server
import json
import pathlib
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time
import urllib.parse


def bencode(value):
    if isinstance(value, int):
        return f"i{value}e".encode()
    if isinstance(value, bytes):
        return str(len(value)).encode() + b":" + value
    if isinstance(value, list):
        return b"l" + b"".join(map(bencode, value)) + b"e"
    return b"d" + b"".join(bencode(key) + bencode(value[key]) for key in sorted(value)) + b"e"


peer_address = sys.argv[2]


def free_port():
    with socket.socket() as connection:
        connection.bind((peer_address, 0))
        return connection.getsockname()[1]


lib = ctypes.CDLL(str(pathlib.Path(sys.argv[1]).resolve()))
for name, args, result in [
    ("rill_open", [ctypes.c_char_p, ctypes.c_char_p], ctypes.c_void_p),
    ("rill_close", [ctypes.c_void_p, ctypes.c_char_p], None),
    ("rill_request", [ctypes.c_void_p, ctypes.c_char_p], ctypes.c_void_p),
    ("rill_preview", [ctypes.c_char_p, ctypes.c_size_t], ctypes.c_void_p),
    ("rill_free", [ctypes.c_void_p], None),
]:
    entry = getattr(lib, name)
    entry.argtypes = args
    entry.restype = result


def parse(pointer):
    assert pointer, "engine timed out"
    try:
        return json.loads(ctypes.string_at(pointer))
    finally:
        lib.rill_free(pointer)


class Engine:
    def __init__(self, folder, port):
        self.folder = folder
        self.port = port
        self.handle = None
        folder.mkdir()
        self.start()

    def start(self):
        options = dict(peer_port=self.port, peer_port_random_on_start=False,
                       bind_address_ipv4=peer_address, bind_address_ipv6="::1",
                       dht_enabled=False, pex_enabled=False, lpd_enabled=False, utp_enabled=False)
        self.handle = lib.rill_open(bytes(self.folder), json.dumps(options).encode())
        assert self.handle

    def close(self):
        if self.handle:
            lib.rill_close(self.handle, bytes(self.folder))
            self.handle = None

    def rpc(self, method, **params):
        request = dict(jsonrpc="2.0", id=1, method=method, params=params)
        result = parse(lib.rill_request(self.handle, json.dumps(request).encode()))
        assert "error" not in result, result
        return result.get("result")

    def status(self):
        fields = ["id", "name", "hash_string", "status", "left_until_done", "percent_done",
                  "metadata_percent_complete", "error", "error_string", "download_dir"]
        transfers = self.rpc("torrent_get", fields=fields)["torrents"]
        return transfers[0] if transfers else {}


def wait_for(engine, predicate, label, seconds=100):
    deadline = time.monotonic() + seconds
    state = {}
    while time.monotonic() < deadline:
        state = engine.status()
        if state and predicate(state):
            print("PASS", label, flush=True)
            return state
        time.sleep(0.2)
    trackers = engine.rpc("torrent_get", fields=["tracker_stats", "peers_connected"])
    raise AssertionError((label, state, trackers))


class Tracker(http.server.BaseHTTPRequestHandler):
    seed_port = free_port()

    def do_GET(self):
        query = urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query)
        requester = int(query.get("port", ["0"])[0])
        peers = b"" if requester == self.seed_port else socket.inet_aton(peer_address) + struct.pack("!H", self.seed_port)
        body = bencode({b"interval": 20, b"complete": 1, b"incomplete": 1, b"peers": peers})
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_):
        pass


if len(sys.argv) > 3 and sys.argv[3] == "--seed":
    folder, download, source, port = sys.argv[4:]
    seed = Engine(pathlib.Path(folder), int(port))
    try:
        seed.rpc("torrent_add", metainfo=base64.b64encode(pathlib.Path(source).read_bytes()).decode(),
                 download_dir=download, paused=False)
        wait_for(seed, lambda s: s["status"] == 6, "seed verifies and starts")
        sys.stdin.readline()
    finally:
        seed.close()
    sys.exit(0)


with tempfile.TemporaryDirectory(prefix="rill-engine-") as temp:
    root = pathlib.Path(temp)
    seed_data, client_data = root / "seed-files", root / "client-files"
    seed_data.mkdir()
    client_data.mkdir()
    payload = hashlib.shake_256(b"Rill loopback check").digest(4 * 1024 * 1024)
    (seed_data / "sample.bin").write_bytes(payload)
    (client_data / "keep.txt").write_text("unrelated")
    piece_size = 32 * 1024
    pieces = b"".join(hashlib.sha1(payload[i:i + piece_size]).digest()
                      for i in range(0, len(payload), piece_size))
    info = {b"name": b"sample.bin", b"length": len(payload), b"piece length": piece_size, b"pieces": pieces}
    torrent_hash = hashlib.sha1(bencode(info)).hexdigest()
    with http.server.ThreadingHTTPServer(("127.0.0.1", 0), Tracker) as tracker:
        thread = threading.Thread(target=tracker.serve_forever, daemon=True)
        thread.start()
        announce = f"http://127.0.0.1:{tracker.server_port}/announce"
        metainfo = bencode({b"announce": announce.encode(), b"info": info})
        preview = parse(lib.rill_preview(metainfo, len(metainfo)))
        assert preview["files"] == [{"name": "sample.bin", "length": len(payload)}], preview
        assert "error" in parse(lib.rill_preview(b"bad", 3))
        print("PASS file preview and malformed import", flush=True)
        source = root / "sample.torrent"
        source.write_bytes(metainfo)
        seed = subprocess.Popen([sys.executable, __file__, sys.argv[1], peer_address, "--seed",
                                 str(root / "seed"), str(seed_data), str(source), str(Tracker.seed_port)],
                                stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
        client = None
        try:
            ready = seed.stdout.readline()
            assert ready.startswith("PASS"), ready
            print(ready.strip(), flush=True)
            client = Engine(root / "client", free_port())
            assert not client.rpc("session_get").get("rpc_enabled", False)
            client.rpc("session_set", speed_limit_down=512, speed_limit_down_enabled=True)
            magnet = f"magnet:?xt=urn:btih:{torrent_hash}&tr={urllib.parse.quote(announce, safe='')}"
            client.rpc("torrent_add", filename=magnet, download_dir=str(client_data), paused=False)
            wait_for(client, lambda s: s["metadata_percent_complete"] == 1 and 0.03 < s["percent_done"] < 0.98,
                     "magnet fetches metadata and partial payload")
            client.rpc("torrent_stop", ids=[torrent_hash])
            stopped = wait_for(client, lambda s: s["status"] == 0, "pause")
            client.close()
            client.port = free_port()
            client.start()
            restored = wait_for(client, lambda s: s["status"] == 0, "restart keeps pause and task")
            assert restored["percent_done"] >= stopped["percent_done"] - 0.02, (stopped, restored)
            assert client.rpc("session_get")["speed_limit_down"] == 512
            client.rpc("session_set", speed_limit_down_enabled=False)

            client.rpc("torrent_start", ids=[torrent_hash])
            wait_for(client, lambda s: s["percent_done"] == 1, "resume completes payload")
            assert hashlib.sha256((client_data / "sample.bin").read_bytes()).digest() == hashlib.sha256(payload).digest()
            print("PASS SHA-256 matches the seed", flush=True)
            duplicate = client.rpc("torrent_add", filename=magnet, download_dir=str(client_data), paused=True)
            assert duplicate["torrent_duplicate"]["hash_string"] == torrent_hash
            client.rpc("torrent_remove", ids=[torrent_hash], delete_local_data=False)
            assert (client_data / "sample.bin").exists()
            assert (client_data / "keep.txt").read_text() == "unrelated"
            print("PASS duplicate detection and removal keeps files", flush=True)
        finally:
            if client:
                client.close()
            seed.stdin.close()
            seed.wait(timeout=20)
            tracker.shutdown()
