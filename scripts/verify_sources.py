"""Static migration checks only: no compiler, synthesis or board access."""
import ast
import json
from pathlib import Path
import re
import xml.etree.ElementTree as ET
import zipfile

ROOT = Path(__file__).resolve().parents[1]
d = json.loads((ROOT/'hardware/bd/design_1.bd').read_text())['design']

def values(component):
    return {k: v['value'] for k, v in component.get('parameters', {}).items()}

assert not any('gmax3412_emulator' in cell for cell in d['components'])
for prefix, cell in [('capture_rx', 'gmax_capture'), ('capture_b_rx', 'gmax_capture_b')]:
    for signal in ['clk', 'data', 'lval', 'fval']:
        endpoints = {f'{prefix}_{signal}', f'{cell}/rx_{signal}'}
        assert any(endpoints <= set(net['ports']) for net in d['nets'].values()), endpoints
pinout = (ROOT/'hardware/constraints/gmax_b.xdc').read_text()
locations = re.findall(r'PACKAGE_PIN (\w+) \[get_ports (GMX_B_\w+)\]', pinout)
assert len({ball for ball, _ in locations}) == len({port for _, port in locations}) == 48
top = (ROOT/'hardware/rtl/FH_Carrier_Bringup_top.v').read_text()
for _, port in locations:
    assert port in top, port

links = [set(n['interface_ports']) for n in d['interface_nets'].values()]
for endpoints in [('fh_export_dma/M_AXI_MM2S', 'pl_ddr_smc/S03_AXI'),
                  ('fh_export_dma/M_AXI_S2MM', 'gmax_ddr_smc/S01_AXI'),
                  ('fh_router_0/s_axi', 'axi_smc/M13_AXI'),
                  ('fh_export_dma/S_AXI_LITE', 'axi_smc/M14_AXI')]:
    assert any(set(endpoints) <= net for net in links), endpoints
for cell in ('gmax_capture', 'gmax_capture_b'):
    assert values(d['components'][cell])['AXIS_WIDTH'] == '256'

xsa = ROOT/'hardware/exports/FH_Firmware_design.xsa'
if xsa.exists():
    with zipfile.ZipFile(xsa) as archive:
        assert not any(n.endswith('.bit') for n in archive.namelist())
        top = ET.fromstring(archive.read('design_1.hwh'))
        cells = {m.get('INSTANCE') for m in top.iter('MODULE')}
        assert set(d['components']) <= cells, set(d['components']) - cells

# Ensure every packaged HDL dependency is present locally.
ns = {'s': 'http://www.spiritconsortium.org/XMLSchema/SPIRIT/1685-2009'}
for component in (ROOT/'hardware/ip').glob('*/component.xml'):
    for f in ET.parse(component).findall('.//s:file/s:name', ns):
        assert (component.parent/f.text).is_file(), f.text
for p in [ROOT/'FH_Test.py', *(ROOT/'scripts').glob('*.py'), *(ROOT/'software/host').glob('*.py')]:
    ast.parse(p.read_text(), filename=str(p))
app = ROOT/'software/app/src'
main = (app/'main.c').read_text()
assert main.count('int main(void)') == 1
assert 'FH_Carrier Bring-Up Test - V31.1' not in main
assert '#define FH_RELEASE "V25.3"' in (app/'fh_version.h').read_text()
assert "RELEASE = 'V25.3'" in (ROOT/'software/host/fh_version.py').read_text()
assert 'toggle_phy_tx_delay' not in (app/'fh_eth_server.c').read_text()
assert 'patch_kfb_phy' not in (ROOT/'scripts/vitis_project.py').read_text()
for p in app.glob('*'):
    if p.suffix in ('.c', '.h'):
        for include in re.findall(r'#include "(fh_[^"]+|dual_stream.h)"', p.read_text()):
            assert (app/include).is_file(), (p, include)
native = ROOT/'software/workspace/FH_TestApp/src'
if native.exists():
    for p in app.iterdir():
        if p.is_file():
            # Vitis may normalize CMake files to Windows line endings on import.
            actual = (native/p.name).read_text()
            if p.name == 'CMakeLists.txt':
                # Vitis inserts the standalone BSP's xilffs into this generated
                # list. The tracked template also selects it by build profile.
                actual = actual.replace('collect(PROJECT_LIB_DEPS xilstandalone;xiltimer;xilffs;lwip220)',
                                        'collect(PROJECT_LIB_DEPS xilstandalone;xiltimer;lwip220)')
            assert actual == p.read_text(), ('native source differs', p.name)
print('PASS: physical sensor interfaces, bank 67 pin coverage, Router connections,')
print('256-bit capture streams, local IP dependencies, Python syntax and software sources.')
print('No compilation, timing signoff or board test performed.')
