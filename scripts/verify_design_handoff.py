"""Reject incomplete/stale pre-synthesis XSA files before Vitis generation."""
from pathlib import Path
import zipfile
import xml.etree.ElementTree as ET
root=Path(__file__).resolve().parents[1]
with zipfile.ZipFile(root/'hardware/exports/FH_Emulator_design.xsa') as z:
    hwh=[n for n in z.namelist() if n.split('/')[-1]=='design_1.hwh']
    assert len(hwh)==1,'Hardware-only XSA lacks a valid HWH; regenerate BD output products'
    assert not any(n.endswith('.bit') for n in z.namelist()),'Design-only XSA unexpectedly contains a bitstream'
    tree=ET.fromstring(z.read(hwh[0]))
    modules={m.get('INSTANCE'):m for m in tree.findall('.//MODULE')}
    for name in ['zynq_ultra_ps_e_0','axi_gpio_gmax_b_ctrl','axi_iic_gmax_b','gmax_dual_ring','gmax_capture_dma','gmax_capture_dma_b','axi_gpio_gmax_a_ctrl','axi_iic_gmax_a','fh_pcie_refclk_monit_0','fh_router_0','fh_export_dma']:
        assert name in modules,name
    for name in ['gmax_capture_dma','gmax_capture_dma_b']:
        ranges=[r for r in modules[name].findall('.//MEMRANGE') if int(r.get('BASEVALUE','0'),0)==0x1000000000]
        assert ranges and all(int(r.get('HIGHVALUE','0'),0)==0x10FFFFFFFF for r in ranges),name
print('DESIGN_HANDOFF_PASS: new dual subsystem and both 4 GiB DMA windows, no bitstream')
