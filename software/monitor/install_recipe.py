#!/usr/bin/env python3
"""Install the monitor recipe in an existing FH_Carrier PetaLinux project."""
import argparse
from pathlib import Path
import shutil
def install(project):
    source=Path(__file__).resolve().parent
    layer=project/"project-spec/meta-user"
    if not layer.is_dir():
        raise ValueError("Expected a PetaLinux project with project-spec/meta-user")
    recipe=layer/"recipes-apps/fh-monitor"
    files=recipe/"files"
    files.mkdir(parents=True,exist_ok=True)
    shutil.copy2(source/"fh-monitor.bb",recipe)
    for name in ("fh_capture.py","fh_monitor_server.py","fh-monitor.service"):
        shutil.copy2(source/name,files)
    shutil.copy2(source.parent/"host/fh_monitor_viewport.py",files)
    conf=layer/"conf/petalinuxbsp.conf"
    entry='IMAGE_INSTALL:append = " fh-monitor"'
    contents=conf.read_text() if conf.exists() else ""
    if entry not in contents.splitlines():
        with conf.open("a") as f:
            f.write("\n"+entry+"\n")
if __name__=="__main__":
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument("project",type=Path)
    install(p.parse_args().project)
