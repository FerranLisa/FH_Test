#!/usr/bin/env python3
"""One shared RTSP/TCP session, two VCU elementary streams in one MPEG-TS."""
import json
import logging
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import gi
gi.require_version("Gst", "1.0")
gi.require_version("GstRtspServer", "1.0")
gi.require_version("GstRtsp", "1.0")
from gi.repository import GLib, Gst, GstRtsp, GstRtspServer
from fh_capture import Capture
from fh_monitor_viewport import Viewport

lock = threading.RLock()
hardware = threading.Lock()
views = (Viewport(), Viewport())
codec = "h264"
generation = 0
media_set = set()
latest_id = None

def make_factory():
    factory = GstRtspServer.RTSPMediaFactory()
    branches = []
    with lock:
        w, h = views[0].width, views[0].height
        fmt = codec
        gen = generation
    for i in range(2):
        branches.append(f'appsrc name=eye{i} is-live=true format=time block=true max-buffers=2 max-bytes=0 '
            f'caps=video/x-raw,format=NV12,width={w},height={h},framerate=10/1 '
            f'! queue max-size-buffers=2 max-size-bytes=0 max-size-time=0 '
            f'! omx{fmt}enc b-frames=0 gop-length=10 periodicity-idr=10 target-bitrate=8000 ! {fmt}parse config-interval=-1 ! mux.sink_{256+i}')
    factory.set_launch('( mpegtsmux name=mux alignment=7 ! rtpmp2tpay name=pay0 pt=33 '
                       + ' '.join(branches) + ' )')
    factory.set_shared(True)
    factory.set_protocols(GstRtsp.RTSPLowerTrans.TCP)
    factory.connect("media-configure", configure_media, gen, w, h)
    return factory

def configure_media(factory, media, gen, w, h):
    stop = threading.Event()
    pipeline = media.get_element()
    sources = [pipeline.get_by_name(f"eye{i}") for i in range(2)]
    def finished(*_):
        stop.set()
        with lock:
            media_set.discard(media)
    media.connect("unprepared", finished)
    with lock:
        media_set.add(media)
    def capture_loop():
        global latest_id
        with hardware:
            if stop.is_set():
                return
            cap = None
            try:
                cap = Capture()
                origin = time.monotonic_ns()
                chroma = bytes([128]) * (w*h//2)
                next_capture = 0
                while not stop.is_set():
                    with lock:
                        if generation != gen:
                            break
                        config = views
                    pair = cap.pair(config, stop)
                    if not pair:
                        continue
                    frame_id, images = pair
                    now = time.monotonic_ns()
                    # Reject excess FULL triggers if U uses R<24. Use an
                    # absolute deadline so polling jitter does not halve 10 Hz.
                    if now < next_capture - 5_000_000:
                        continue
                    next_capture = max(next_capture+100_000_000, now+95_000_000)
                    for src, luma in zip(sources, images):
                        buf = Gst.Buffer.new_allocate(None, len(luma)+len(chroma), None)
                        buf.fill(0,luma); buf.fill(len(luma),chroma)
                        buf.pts = now-origin
                        buf.duration = 100_000_000
                        buf.offset = frame_id
                        if src.emit("push-buffer",buf) != Gst.FlowReturn.OK:
                            return
                    with lock:
                        latest_id = frame_id
            except Exception:
                logging.exception("Stereo capture failed")
            finally:
                if cap:
                    cap.close()
                for src in sources:
                    src.emit("end-of-stream")
    threading.Thread(target=capture_loop,daemon=True).start()

def remount():
    with lock:
        old = list(media_set)
    for media in old:
        media.unprepare()
    mounts.add_factory("/stereo",make_factory())
    return False

class Control(BaseHTTPRequestHandler):
    def reply(self, code, data):
        body = json.dumps(data).encode()
        self.send_response(code)
        self.send_header("Content-Type","application/json")
        self.send_header("Content-Length",str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path != "/monitor":
            return self.reply(404,{})
        with lock:
            self.reply(200,dict(codec=codec,views=[vars(v) for v in views],frame_id=latest_id))

    def do_PUT(self):
        global views,codec,generation
        if self.path != "/monitor":
            return self.reply(404,{})
        try:
            length=int(self.headers.get("Content-Length","0"))
            if not 0 < length <= 2048:
                raise ValueError("Invalid body length")
            data=json.loads(self.rfile.read(length))
            if not isinstance(data,dict):
                raise ValueError("Expected a configuration object")
            selected=data["codec"]
            pair=tuple(Viewport(**v) for v in data["views"])
            if (selected not in ("h264","h265") or len(pair)!=2 or
                (pair[0].width,pair[0].height)!=(pair[1].width,pair[1].height) or
                any(type(n) is not int for v in pair for n in vars(v).values())):
                raise ValueError("Invalid stereo configuration")
        except (KeyError,ValueError,TypeError) as exc:
            return self.reply(400,dict(error=str(exc)))
        with lock:
            restart=selected!=codec or pair[0].width!=views[0].width
            codec,views=selected,pair
            if restart:
                generation+=1
        if restart:
            changed=threading.Event()
            def apply():
                try:
                    remount()
                finally:
                    changed.set()
                return False
            GLib.idle_add(apply)
            if not changed.wait(5):
                return self.reply(503,dict(error="Reconfiguration timeout"))
        self.reply(200,dict(reconnect=restart))

if __name__=="__main__":
    Gst.init(None)
    server=GstRtspServer.RTSPServer()
    server.set_service("8554")
    mounts=server.get_mount_points()
    remount()
    if not server.attach(None):
        raise RuntimeError("RTSP listener failed")
    control=ThreadingHTTPServer(("",8555),Control)
    threading.Thread(target=control.serve_forever,daemon=True).start()
    GLib.MainLoop().run()
