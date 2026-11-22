SUMMARY = "FH stereo VCU monitor"
LICENSE = "CLOSED"
SRC_URI = "file://fh_capture.py file://fh_monitor_server.py file://fh_monitor_viewport.py file://fh-monitor.service"
inherit systemd
SYSTEMD_SERVICE:${PN} = "fh-monitor.service"
RDEPENDS:${PN} += "python3-modules python3-pygobject gstreamer1.0-omx gstreamer1.0-rtsp-server gstreamer1.0-plugins-base-app gstreamer1.0-plugins-good-rtp gstreamer1.0-plugins-bad-mpegtsmux gstreamer1.0-plugins-bad-videoparsersbad"
FH_UNPACK = "${@d.getVar('UNPACKDIR') or d.getVar('WORKDIR')}"
do_install() {
    install -d ${D}/opt/fh-monitor ${D}${systemd_system_unitdir}
    for s in fh_capture.py fh_monitor_server.py fh_monitor_viewport.py; do
        install -m 0644 ${FH_UNPACK}/$s ${D}/opt/fh-monitor/
    done
    install -m 0644 ${FH_UNPACK}/fh-monitor.service ${D}${systemd_system_unitdir}/
}
FILES:${PN} += "/opt/fh-monitor"
