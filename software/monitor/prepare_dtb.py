#!/usr/bin/env python3
"""Prepare a separate AMP DTB from the device tree generated for the monitor XSA."""
import argparse
import os
import shutil
import subprocess
import tempfile
from pathlib import Path

def prepare(source, destination):
    if source.resolve()==destination.resolve():
        raise ValueError("Use a separate output DTB")
    with tempfile.TemporaryDirectory(dir=destination.parent) as tmp:
        dt=Path(tmp)/"amp.dtb"
        shutil.copyfile(source,dt)
        def get(node, prop, kind="s"):
            p=subprocess.run(["fdtget","-t",kind,str(dt),node,prop],
                             capture_output=True,text=True)
            return p.stdout.strip() if p.returncode==0 else ""
        def put(node, prop, *values, kind="s"):
            subprocess.run(["fdtput","-t",kind,str(dt),node,prop,*values],check=True)
        def paths(node="/"):
            yield node
            children=subprocess.check_output(["fdtget","-l",str(dt),node],text=True)
            for name in children.splitlines():
                yield from paths(node.rstrip("/")+"/"+name)
        nodes=list(paths())
        if get("/","#address-cells","i")!="2" or get("/","#size-cells","i")!="2":
            raise ValueError("Expected the ZynqMP 64-bit address map")
        def reserve(name,address,size):
            base="/reserved-memory"
            if base not in nodes:
                subprocess.run(["fdtput","-p","-c",str(dt),base],check=True)
                put(base,"#address-cells","2",kind="i")
                put(base,"#size-cells","2",kind="i")
                subprocess.run(["fdtput",str(dt),base,"ranges"],check=True)
                nodes.append(base)
            node=f"{base}/{name}@{address:x}"
            subprocess.run(["fdtput","-p","-c",str(dt),node],check=True)
            put(node,"reg","0",f"{address:x}","0",f"{size:x}",kind="x")
            subprocess.run(["fdtput",str(dt),node,"no-map"],check=True)
        reserve("fh-monitor",0x34000000,0x800000)
        reserve("fh-vitis",0x40000000,0x10000000)
        if not any("vcu" in get(n,"compatible").lower() for n in nodes):
            raise ValueError("VCU device missing from the generated Linux device tree")
        cpu3=[n for n in nodes if get(n,"device_type")=="cpu" and
              int(get(n,"reg","x").replace(" ","") or "0",16)==3]
        if len(cpu3)!=1:
            raise ValueError("Could not identify A53 #3")
        put(cpu3[0],"status","disabled")
        # Remove PSCI enable-method too: Linux can otherwise online a disabled CPU.
        if get(cpu3[0],"enable-method"):
            subprocess.run(["fdtput","-d",str(dt),cpu3[0],"enable-method"],check=True)
        resources={0xff000000,0xff020000,0xff030000,0xff0a0000,0xffa60000,
                   0xfd0c0000}
        found=set()
        for n in nodes:
            if "@" not in n:
                continue
            try:
                addr=int(n.rsplit("@",1)[1],16)
            except ValueError:
                continue
            if addr in resources or 0xa0000000 <= addr < 0xa2000000:
                put(n,"status","disabled")
                found.add(addr)
        if not {0xa1000000,0xa1040000}.issubset(found):
            raise ValueError("DTB does not contain both live monitor GPIOs; check XSA")
        bootargs=get("/chosen","bootargs").split()
        bootargs=[v for v in bootargs if not v.startswith(("console=","earlycon","cma="))]
        put("/chosen","bootargs"," ".join(bootargs+["console=tty0","clk_ignore_unused",
            "pd_ignore_unused","cma=256M@0x50000000-0x70000000","maxcpus=3"]))
        if get("/chosen","stdout-path"):
            subprocess.run(["fdtput","-d",str(dt),"/chosen","stdout-path"],check=True)
        os.replace(dt,destination)

if __name__=="__main__":
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument("input",type=Path); p.add_argument("output",type=Path)
    args=p.parse_args(); prepare(args.input,args.output)
