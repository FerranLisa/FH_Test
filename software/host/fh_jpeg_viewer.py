"""Bare-metal stereo JPEG monitor. Each request names a sensor ROI per eye."""
import socket
import struct
import threading
import time

from view_stereo import QtCore, QtGui, QtWidgets, enum
from fh_jpeg_view import EyeView, W, H


def read_exact(sock, count):
    result=bytearray(count)
    view=memoryview(result)
    while view:
        received=sock.recv_into(view)
        if not received:
            raise ConnectionError("Board closed the monitor connection")
        view=view[received:]
    return result


class Eye(QtWidgets.QLabel):
    anchor=QtCore.pyqtSignal(bool,float,float)

    def wheelEvent(self,event):
        pix=self.pixmap()
        if pix is None or pix.isNull():
            return
        pos=event.position() if hasattr(event,"position") else event.pos()
        u=(pos.x()-(self.width()-pix.width())/2)/pix.width()
        v=(pos.y()-(self.height()-pix.height())/2)/pix.height()
        if 0<=u<=1 and 0<=v<=1 and event.angleDelta().y():
            self.anchor.emit(event.angleDelta().y()>0,u,v)
            event.accept()


class StereoMonitor(QtCore.QObject):
    def __init__(self,host,eyes,status,parent):
        super().__init__(parent)
        self.host=host
        self.views=(EyeView(),EyeView())
        self.displayed=None
        self.lock=threading.Lock()
        self.stop=threading.Event()
        self.latest=None
        self.sock=None
        self.message="Waiting for U capture"
        self.eyes=eyes
        self.status=status
        self.worker=threading.Thread(target=self.receive,daemon=True)
        self.worker.start()
        self.timer=QtCore.QTimer(self)
        self.timer.timeout.connect(self.refresh)
        self.timer.start(40)

    def overview(self,*_):
        with self.lock:
            self.views=(EyeView(),EyeView())
        self.refresh()

    def zoom(self,eye,inward,u,v):
        if self.displayed is None:
            return
        with self.lock:
            views=list(self.displayed)
            views[eye]=views[eye].wheel(inward,u,v)
            views[1-eye]=views[1-eye].wheel(inward,.5,.5)
            self.views=tuple(views)
        self.refresh()

    def receive(self):
        while not self.stop.is_set():
            try:
                with socket.create_connection((self.host,5002),timeout=2) as sock:
                    sock.settimeout(5)
                    with self.lock:
                        self.sock=sock
                    while not self.stop.is_set():
                        with self.lock:
                            a,b=self.views
                        sock.sendall(struct.pack("<4s5I",b"FHR1",a.step,a.x,a.y,b.x,b.y))
                        magic,frame_id,na,nb=struct.unpack("<4s3I",read_exact(sock,16))
                        if magic!=b"FHJ1" or not all(0<n<=W*H*4 for n in (na,nb)):
                            raise ValueError("Invalid stereo JPEG header")
                        images=[]
                        for size in (na,nb):
                            image=QtGui.QImage.fromData(bytes(read_exact(sock,size)),"JPEG")
                            if (image.width(),image.height())!=(W,H):
                                raise ValueError("Invalid JPEG dimensions")
                            images.append(image)
                        with self.lock:
                            self.latest=(images,(a,b),frame_id,time.monotonic())
                            self.message="Live"
            except (OSError,ValueError) as exc:
                with self.lock:
                    self.message=f"Waiting for U on TCP 5002 · {exc}"
                self.stop.wait(.5)
            finally:
                with self.lock:
                    self.sock=None

    def refresh(self):
        with self.lock:
            latest,requested,message=self.latest,self.views,self.message
        if latest is None:
            self.status.setText(message)
            return
        images,applied,frame_id,received=latest
        # Local zoom updates immediately, even if the next JPEG is still in flight.
        visible=tuple(v if v.wire()==a.wire() else a for v,a in zip(requested,applied))
        for label,image,v in zip(self.eyes,images,visible):
            w,h=v.local_size
            cropped=image.copy(v.local_x,v.local_y,w,h) if v.level>2 else image
            label.setPixmap(QtGui.QPixmap.fromImage(cropped).scaled(label.size(),
                enum(QtCore.Qt,"AspectRatioMode","KeepAspectRatio")))
        self.displayed=visible
        state="Stale" if time.monotonic()-received>.5 else message
        self.status.setText(f"{state} · FrameID {frame_id} · {2**visible[0].level}×")

    def close(self):
        self.stop.set()
        self.timer.stop()
        with self.lock:
            if self.sock:
                try:
                    self.sock.shutdown(socket.SHUT_RDWR)
                except OSError:
                    pass
        self.deleteLater()
