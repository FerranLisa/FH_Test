"""Vitis 2025.2 stages, selected by FH_VITIS_STAGE. No action on import.
Creates a fresh platform from the NEW XSA; never copies an old BSP/psu_init.
"""
from pathlib import Path
import os
import socket
import time
import hashlib
import sys
import vitis
import platform_pb2
import build_pb2
import workspace_pb2

ROOT=Path(__file__).resolve().parents[1]
AMP=os.environ.get('FH_MONITOR_AMP') == '1'
WORKSPACE=ROOT/('software/workspace_amp' if AMP else 'software/workspace')
PLATFORM='FH_Emulator_platform'
APP='FH_Emulator_App'
DOMAIN='standalone'  # Keep generated Windows object paths below 250 characters.
XSA=ROOT/'hardware/exports/FH_Emulator.xsa'
if not XSA.is_file(): XSA=ROOT/'hardware/exports/FH_Emulator_design.xsa'
LWIP={
    'lwip220_api_mode':'RAW_API',
    'lwip220_no_sys_no_timers':'true',
    'lwip220_ipv6_enable':'false',
    'lwip220_dhcp':'false',
    'lwip220_tcp':'true',
    'lwip220_tcp_snd_buf':'32768',
    'lwip220_tcp_wnd':'16384',
    'lwip220_memp_n_tcp_seg':'512',
    'lwip220_mem_size':'262144',
}

def configure_domain(domain):
    for name in ('standalone_stdin','standalone_stdout'):
        if domain.get_config('os',name)['value'] != 'psu_uart_0':
            domain.set_config('os',name,'psu_uart_0')
    libraries = domain.get_libs()
    if not AMP and not any(lib['name'] == 'xilffs' for lib in libraries):
        domain.set_lib('xilffs')
    if not any(lib['name'] == 'lwip220' for lib in libraries):
        domain.set_lib('lwip220')
    else:
        print('lwip220 is already present; keeping its configuration.',flush=True)
    for name,value in LWIP.items():
        current = domain.get_config('lib',name,'lwip220')['value']
        if str(current) == value:
            print(f'Already configured: {name}={value}',flush=True)
            continue
        print(f'Setting {name}: {current} -> {value}',flush=True)
        try:
            domain.set_config('lib',name,value,'lwip220')
        except Exception as exc:
            raise RuntimeError(f'Failed configuring {name}={value}: {exc}') from exc
        actual = domain.get_config('lib',name,'lwip220')['value']
        if str(actual) != value:
            raise RuntimeError(f'{name}: expected {value}, read back {actual}')

def open_workspace(client):
    # A preceding Vitis server can take a few seconds to release the workspace.
    # Never remove lock files or terminate another session.
    for attempt in range(11):
        try:
            client.set_workspace(str(WORKSPACE))
            return
        except Exception as exc:
            if 'already in use' not in str(exc).lower():
                raise
            if attempt == 10:
                raise RuntimeError(
                    'Workspace remained locked for 30 seconds. Close the Vitis GUI '
                    'using software/workspace, then retry. No lock files were removed.'
                ) from exc
            print('Workspace still in use; waiting 3 seconds for the previous session to release it...',flush=True)
            time.sleep(3)

class UpdatedPlatformDisconnected(RuntimeError):
    """The XSA update completed but its Vitis session is unavailable."""

def main():
    stage=os.environ['FH_VITIS_STAGE']
    if not XSA.is_file(): raise RuntimeError('Export the new design handoff or final FH_Emulator XSA first')
    # An explicit free port avoids Vitis 2025.2's EOF loop if its Java server
    # exits before printing an automatically selected port.
    if os.environ.get('FH_VITIS_PORT'):
        port=int(os.environ['FH_VITIS_PORT'])
    else:
        with socket.socket() as probe:
            probe.bind(('127.0.0.1',0))
            port=probe.getsockname()[1]
    print(f'Creating Vitis client for {stage} on local port {port}',flush=True)
    client=vitis.create_client(port=port)
    workspace_open=False
    try:
        open_workspace(client)
        workspace_open=True
        if stage=='CreatePlatform':
            if (WORKSPACE/PLATFORM).exists():
                print('Resuming configuration of existing platform.',flush=True)
                platform=client.get_component(name=PLATFORM)
            else:
                platform=client.create_platform_component(name=PLATFORM,hw_design=str(XSA),
                    cpu='psu_cortexa53_3' if AMP else 'psu_cortexa53_0',os='standalone',domain_name=DOMAIN,
                    architecture='64-bit',no_boot_bsp=False)
            domain=platform.get_domain(name=DOMAIN)
            configure_domain(domain)
            print('Platform configured. BuildPlatform generates and compiles BSP/FSBL next.')
        elif stage=='BuildPlatform':
            platform=client.get_component(name=PLATFORM)
            final_xsa=ROOT/'hardware/exports/FH_Emulator.xsa'
            if not final_xsa.is_file():
                raise RuntimeError('Run implementation and Export first; the design-only XSA has no bitstream')
            imported_xsa=WORKSPACE/PLATFORM/'hw'/final_xsa.name
            updated=False
            if (not imported_xsa.is_file() or
                hashlib.sha256(imported_xsa.read_bytes()).digest() !=
                hashlib.sha256(final_xsa.read_bytes()).digest()):
                platform.update_hw(hw_design=str(final_xsa))
                updated=True
            else:
                print('Hardware XSA unchanged; preserving generated BSP/FSBL build state.',flush=True)
            try:
                domain=platform.get_domain(name=DOMAIN)
            except Exception as exc:
                if updated and 'StatusCode.UNAVAILABLE' in str(exc):
                    raise UpdatedPlatformDisconnected(str(exc)) from exc
                raise
            configure_domain(domain)
            status=platform.build()
            if status!=platform_pb2.PlatformResponse.SUCCESS:
                raise RuntimeError(f'Platform build failed (Vitis status={status}); inspect software/logs')
            include=WORKSPACE/PLATFORM/'export'/PLATFORM/'sw'/DOMAIN/'include'
            opts=(include/'lwipopts.h').read_text()
            import re
            if not re.search(r'#define\s+MEMP_NUM_TCP_SEG\s+512\b',opts):
                raise RuntimeError('Regenerated lwipopts.h does not contain MEMP_NUM_TCP_SEG=512')
        elif stage=='CreateApp':
            if (WORKSPACE/APP).exists(): raise RuntimeError('Application exists; edit/build it without reimporting')
            xpfm=WORKSPACE/PLATFORM/'export'/PLATFORM/(PLATFORM+'.xpfm')
            if not xpfm.is_file():
                found=client.find_platform_in_repos(PLATFORM)
                if not found: raise RuntimeError('Vitis has not exported the platform metadata yet')
                xpfm=Path(found)
            app=client.create_app_component(name=APP,platform=str(xpfm),domain=DOMAIN,template='empty_application')
            # One initial import. The native component's src becomes authoritative.
            app.import_files(from_loc=str(ROOT/'software/app/src'),dest_dir_in_cmp='src')
            if AMP:
                src=WORKSPACE/APP/"src"
                linker=src/"lscript.ld"
                layout=linker.read_text().replace("ORIGIN = 0x0, LENGTH = 0x10000000",
                    "ORIGIN = 0x40000000, LENGTH = 0x10000000").replace(
                    "ASSERT(_end <= 0x10000000", "ASSERT(_end <= 0x50000000")
                if "ORIGIN = 0x40000000" not in layout:
                    raise RuntimeError("AMP linker region missing")
                linker.write_text(layout)
                cmake=src/"CMakeLists.txt"
                cmake.write_text(cmake.read_text().replace("enable_language(C ASM CXX)",
                    "enable_language(C ASM CXX)\nadd_compile_definitions(FH_MONITOR_AMP=1)"))
            print(f'Application created. Native application sources: {WORKSPACE/APP/"src"}')
        elif stage=='BuildApp':
            if client.get_component(name=APP).build()!=build_pb2.BuildResponse.SUCCESS:
                raise RuntimeError('Application build failed')
        else: raise ValueError(stage)
    finally:
        failed=sys.exc_info()[0] is not None
        try:
            if workspace_open:
                # Vitis 2025.2 dispose() force-kills its Windows launcher; it
                # does not call the server's workspace-close RPC. Release the
                # workspace explicitly before terminating our server.
                response=client._serverObj.stubWs.closeWorkspace(
                    workspace_pb2.CloseWorkspaceRequest(path=str(WORKSPACE)),timeout=15)
                if not response.status:
                    raise RuntimeError('Vitis did not confirm workspace release')
                print('Workspace released.',flush=True)
        except Exception as exc:
            if not failed:
                raise
            print(f'Workspace cleanup after failure: {exc}',flush=True)
        finally:
            try:
                vitis.dispose()
            except Exception:
                if not failed:
                    raise

if __name__=='__main__':
    try:
        main()
    except UpdatedPlatformDisconnected:
        print('XSA updated. Resuming BuildPlatform with a fresh Vitis session.',flush=True)
        main()
    if os.environ.get('FH_VITIS_RESULT'):
        Path(os.environ['FH_VITIS_RESULT']).write_text(os.environ['FH_VITIS_STAGE']+'\n')
