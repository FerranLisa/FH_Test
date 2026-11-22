"""Check the new XSA and delivered BIT after Export. Read-only."""
from pathlib import Path
import hashlib, zipfile
import xml.etree.ElementTree as ET
root=Path(__file__).resolve().parents[1]
stem=root/'hardware/exports/FH_Emulator'
with zipfile.ZipFile(stem.with_suffix('.xsa')) as z:
    bits=[n for n in z.namelist() if n.endswith('.bit')]
    assert len(bits)==1,'Expected exactly one embedded bitstream'
    assert hashlib.sha256(z.read(bits[0])).digest()==hashlib.sha256(stem.with_suffix('.bit').read_bytes()).digest(),'XSA/BIT mismatch'
    hwh=[n for n in z.namelist() if n.split('/')[-1]=='design_1.hwh']
    assert len(hwh)==1,'Expected one HWH'
    tree=ET.fromstring(z.read(hwh[0]))
    modules={m.get('INSTANCE'):m for m in tree.findall('.//MODULE')}
    for name in ['axi_gpio_gmax_b_ctrl','axi_iic_gmax_b','gmax_dual_ring','pl_ddr4','gmax_capture_dma','gmax_capture_dma_b']:
        assert name in modules,name
    for name in ['gmax_scheduler','gmax_pl_ring','axi_gpio_gmax_a_ctrl','axi_iic_gmax_a','fh_pcie_refclk_monit_0','fh_router_0','fh_export_dma']:
        assert name in modules,name
    for name in ('monitor_a','monitor_b','monitor_a_dma','monitor_b_dma'):
        assert name in modules, f'Monitor component missing from hardware handoff: {name}'
    for name in ['gmax_capture_dma','gmax_capture_dma_b']:
        parameters={p.get('NAME').lower():p.get('VALUE') for p in modules[name].findall('.//PARAMETER')}
        assert int(parameters['c_addr_width'],0)==64,name
        ranges=[r for r in modules[name].findall('.//MEMRANGE') if int(r.get('BASEVALUE','0'),0)==0x1000000000]
        assert ranges and all(int(r.get('HIGHVALUE','0'),0)==0x10FFFFFFFF for r in ranges),f'{name}: missing full 4 GiB DDR aperture'
print('EXPORT_IDENTITY_PASS: embedded BIT matches; dual subsystem and 64-bit DMAs present')
