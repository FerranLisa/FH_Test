"""Live A/B viewer. Network and decoder objects belong to a worker thread."""
import json
import threading
import time
from urllib.request import Request, urlopen
from view_stereo import QtCore, QtGui, QtWidgets, enum
from fh_monitor_viewport import Viewport, OUTPUT_SIZES


class Eye(QtWidgets.QLabel):
    anchor = QtCore.pyqtSignal(bool,float,float)

    moved = QtCore.pyqtSignal(float,float)

    def mousePressEvent(self,event):
        if event.button()==enum(QtCore.Qt,"MouseButton","LeftButton"):
            self.drag_start=event.pos()

    def mouseReleaseEvent(self,event):
        start=getattr(self,"drag_start",None)
        self.drag_start=None
        pix=self.pixmap()
        if start is not None and pix is not None and not pix.isNull():
            delta=start-event.pos()
            self.moved.emit(delta.x()/pix.width(),delta.y()/pix.height())

    def wheelEvent(self,event):
        pix = self.pixmap()
        if pix is None or pix.isNull():
            return
        pos = event.position() if hasattr(event,"position") else event.pos()
        u=(pos.x()-(self.width()-pix.width())/2)/pix.width()
        v=(pos.y()-(self.height()-pix.height())/2)/pix.height()
        if 0<=u<=1 and 0<=v<=1 and event.angleDelta().y():
            self.anchor.emit(event.angleDelta().y()>0,u,v)
            event.accept()


class StereoMonitor(QtWidgets.QDialog):
    def __init__(self, host, parent):
        super().__init__(parent)
        self.host=host
        self.setWindowTitle("Stereo monitor")
        self.resize(1000,490)
        self.lock=threading.Lock()
        self.stop=threading.Event()
        self.config=None
        self.latest=None
        self.message="Waiting for FULL captures"
        outer=QtWidgets.QVBoxLayout(self)
        options=QtWidgets.QHBoxLayout()
        outer.addLayout(options)
        self.codec=QtWidgets.QComboBox()
        self.codec.addItems(["H.264","H.265"])
        self.size=QtWidgets.QComboBox()
        self.size.addItems([f"{w} × {h} per camera" for w,h in OUTPUT_SIZES])
        options.addWidget(self.codec); options.addWidget(self.size)
        reset=QtWidgets.QPushButton("Full field")
        options.addWidget(reset); options.addStretch()
        pair=QtWidgets.QHBoxLayout()
        outer.addLayout(pair,1)
        self.eyes=[]
        for i in range(2):
            label=Eye("GMAX3412-"+("A","B")[i])
            label.setMinimumSize(100,100)
            label.setAlignment(enum(QtCore.Qt,"AlignmentFlag","AlignCenter"))
            label.anchor.connect(lambda inward,u,v,eye=i:self.zoom(eye,inward,u,v))
            label.moved.connect(lambda dx,dy,eye=i:self.pan(eye,dx,dy))
            pair.addWidget(label,1)
            self.eyes.append(label)
        self.status=QtWidgets.QLabel()
        outer.addWidget(self.status)
        self.size.currentIndexChanged.connect(self.overview)
        self.codec.currentIndexChanged.connect(self.configure)
        reset.clicked.connect(self.overview)
        self.overview()
        self.worker=threading.Thread(target=self.receive,daemon=True)
        self.worker.start()
        self.timer=QtCore.QTimer(self)
        self.timer.timeout.connect(self.refresh)
        self.timer.start(50)

    def overview(self,*_):
        view=Viewport.overview(*OUTPUT_SIZES[self.size.currentIndex()])
        self.views=[view,view]
        self.configure()

    def zoom(self,eye,inward,u,v):
        new=self.views[eye].wheel(inward,u,v)
        other=self.views[1-eye]
        # Match magnification around the other eye's current centre.
        if new.step!=self.views[eye].step:
            self.views[eye]=new
            self.views[1-eye]=other.wheel(inward,.5,.5)
            self.configure()

    def pan(self,eye,dx,dy):
        view=self.views[eye]
        x=max(0,min(4096-view.width*view.step,round(view.x+dx*view.width*view.step)))
        y=max(0,min(3072-view.height*view.step,round(view.y+dy*view.height*view.step)))
        self.views[eye]=Viewport(view.width,view.height,x,y,view.step)
        self.configure()

    def configure(self,*_):
        blob=json.dumps(dict(codec=("h264","h265")[self.codec.currentIndex()],
                             views=[vars(v) for v in self.views])).encode()
        with self.lock:
            self.config=blob

    def receive(self):
        try:
            import av
        except ImportError:
            self.message="Install the host requirement av to decode RTSP video."
            return
        applied=None
        http=f"http://{self.host}:8555/monitor"
        rtsp=f"rtsp://{self.host}:8554/stereo"
        while not self.stop.is_set():
            try:
                with self.lock:
                    desired=self.config
                if desired!=applied:
                    with urlopen(Request(http,data=desired,method="PUT",
                                 headers={"Content-Type":"application/json"}),timeout=5) as r:
                        json.load(r)
                    applied=desired
                with av.open(rtsp,options={"rtsp_transport":"tcp","max_delay":"0"},
                             timeout=(5,2)) as container:
                    tracks=sorted(container.streams.video,key=lambda s:s.id)
                    if len(tracks)!=2:
                        raise RuntimeError("Expected two video tracks in the stereo transport")
                    pending={}
                    for packet in container.demux(*tracks):
                        if self.stop.is_set():
                            return
                        with self.lock:
                            desired=self.config
                        if desired!=applied:
                            with urlopen(Request(http,data=desired,method="PUT",
                                         headers={"Content-Type":"application/json"}),timeout=5) as r:
                                reconnect=json.load(r)["reconnect"]
                            applied=desired
                            pending.clear()
                            if reconnect:
                                break
                        eye=int(packet.stream.index==tracks[1].index)
                        for frame in packet.decode():
                            if frame.pts is None:
                                continue
                            timestamp=frame.pts*frame.time_base
                            entry=pending.setdefault(timestamp,{})
                            entry[eye]=frame
                            if len(entry)==2:
                                images=[entry[i].to_ndarray(format="gray") for i in range(2)]
                                with self.lock:
                                    self.latest=(images,time.monotonic())
                                pending={k:v for k,v in pending.items() if k>timestamp}
                                self.message="Live"
                            while len(pending)>4:
                                del pending[min(pending)]
            except Exception as exc:
                self.message=str(exc)
                applied=None
                self.stop.wait(.75)

    def refresh(self):
        with self.lock:
            latest=self.latest
        self.status.setText(self.message)
        if latest is None:
            return
        images,received=latest
        if time.monotonic()-received>.5:
            self.status.setText("Waiting for a new stereo pair · "+self.message)
        for img,label in zip(images,self.eyes):
            h,w=img.shape
            picture=QtGui.QImage(img.data,w,h,img.strides[0],
                                 enum(QtGui.QImage,"Format","Format_Grayscale8"))
            label.setPixmap(QtGui.QPixmap.fromImage(picture).scaled(label.size(),
                enum(QtCore.Qt,"AspectRatioMode","KeepAspectRatio")))

    def done(self,result):
        self.stop.set()
        self.timer.stop()
        super().done(result)
