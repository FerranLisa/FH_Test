#!/usr/bin/env python3
"""Apply the GMAX3412 16-channel Sub-LVDS fix to local FH_Emulator sources.

Usage (Windows): py apply_fh_emulator_16ch.py C:\\Projects\\FH_Emulator
Only handwritten firmware sources are modified; build output is excluded.
"""
from __future__ import annotations

import argparse
import difflib
from datetime import datetime
from pathlib import Path
import re
import subprocess
import sys

SKIP_PARTS = {".git", ".xil", "build", "debug", "release", "_build", "generated",
              "bsp", "platform", "export", "exports", "ip_user_files", ".metadata"}
ENTRY_12 = re.compile(r"(\{\s*0x3009U?\s*,\s*)0x06U?(?=\s*\})")
ENTRY_16 = re.compile(r"\{\s*0x3009U?\s*,\s*0x08U?\s*\}")
REG_CHECK = re.compile(r"(?m)^(\s*if\s*\(\s*gmax_verify_reg8\(0x3004U[^\r\n]*;)(\r?\n)")


def source_files(root: Path) -> list[Path]:
    files = []
    for suffix in ("*.c", "*.cpp"):
        for f in root.rglob(suffix):
            rel = f.relative_to(root)
            if any(part.lower() in SKIP_PARTS for part in rel.parts):
                continue
            if len(f.parts) > 35:
                continue
            files.append(f)
    return sorted(set(files))


def patch(text: str) -> tuple[str, list[str]]:
    notes: list[str] = []
    if "Gmax10b1200Config" not in text:
        return text, notes
    updated, n = ENTRY_12.subn(lambda m: m.group(1) + "0x08U", text)
    if n != 1:
        return text, notes
    notes.append("I2C 0x3009 CHAN_NUM: 0x06 (12 lanes) -> 0x08 (16 lanes)")
    # Fix the misleading 0x3004 label: LANE_NUM is a MIPI setting, not CHAN_NUM.
    updated = updated.replace('"LVDS lanes") != XST_SUCCESS',
                              '"MIPI lane count") != XST_SUCCESS')
    if "gmax_verify_reg8(0x3009U" not in updated:
        newline = "\r\n" if "\r\n" in updated else "\n"
        def insert_check(m: re.Match[str]) -> str:
            indent = re.match(r"\s*", m.group(1)).group(0)  # initial indentation
            check = f'{indent}if (gmax_verify_reg8(0x3009U, 0x08U, "Sub-LVDS CHAN_NUM (16 lanes)") != XST_SUCCESS) VerifyOk = 0;'
            return m.group(1) + m.group(2) + check + m.group(2)
        updated, verify_count = REG_CHECK.subn(insert_check, updated, count=1)
        if verify_count:
            notes.append("I2C post-upload readback verifies CHAN_NUM=8")
        else:
            notes.append("No matching readback block found; validate 0x3009 manually")
    # Extend the pre-existing v16 diagnostic when its known anchors are present.
    start = updated.find("static int gmax_read_rx_training_registers(u16 *TrainingWord)")
    end = updated.find("static int gmax_raw_rx_diagnostic(void)", start) if start >= 0 else -1
    if start >= 0 and end > start:
        section = updated[start:end]
        indented_newline = "\r\n" if "\r\n" in section else "\n"
        anchors = (
            "    u8 OutMode;" + indented_newline + "    u8 HloOrder;",
            "    if (gmax_i2c_read8_at(GMAX_I2C_ADDR_0, GMAX_I2C_REG_HLO_ORDER, &HloOrder) != XST_SUCCESS)",
            '    xil_printf("  0x3010 HLO_ORDER',
            "    if ((HloOrder & 0x01U) != 0x01U) {",
        )
        if all(a in section for a in anchors) and '0x3009 CHAN_NUM' not in section:
            section = section.replace(anchors[0],
                "    u8 OutMode;" + indented_newline + "    u8 ChanNum;" + indented_newline + "    u8 HloOrder;", 1)
            section = section.replace(anchors[1],
                "    if (gmax_i2c_read8_at(GMAX_I2C_ADDR_0, 0x3009U, &ChanNum) != XST_SUCCESS)" + indented_newline +
                "        return XST_FAILURE;" + indented_newline + anchors[1], 1)
            section = section.replace(anchors[2],
                '    xil_printf("  0x3009 CHAN_NUM   : 0x%02X  (%u/16 data channels)\\r\\n",' + indented_newline +
                '               ChanNum, ((ChanNum & 0x0FU) == 0U) ? 1U :' + indented_newline +
                '               ((ChanNum & 0x0FU) <= 8U ? 2U * (unsigned int)(ChanNum & 0x0FU) : 0U));' +
                indented_newline + anchors[2], 1)
            section = section.replace(anchors[3],
                '    if ((ChanNum & 0x0FU) != 0x08U) {' + indented_newline +
                '        xil_printf("  CHECK: CHAN_NUM=8 required for D0..D15.\\r\\n");' + indented_newline +
                '        Ok = 0;' + indented_newline + '    }' + indented_newline + anchors[3], 1)
            updated = updated[:start] + section + updated[end:]
            notes.append("V16 diagnostic reads and validates CHAN_NUM")
    return updated, notes


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", nargs="?", default=r"C:\Projects\FH_Emulator")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    root = Path(args.root).expanduser()
    if not root.is_dir():
        print(f"ERROR: project directory unavailable: {root}", file=sys.stderr)
        return 2
    eligible = []
    already = []
    for path in source_files(root):
        try:
            raw = path.read_bytes()
            text = raw.decode("utf-8-sig")
        except (OSError, UnicodeError):
            continue
        if "Gmax10b1200Config" not in text:
            continue
        new, notes = patch(text)
        if notes:
            eligible.append((path, raw, text, new, notes))
        elif ENTRY_16.search(text):
            already.append(path)
    if not eligible:
        if already:
            print("Already configured for 16 Sub-LVDS outputs in:")
            for path in already:
                print(f"  {path}")
            return 0
        print("ERROR: No matching handwritten GMAX3412 configuration found in FH_Emulator.", file=sys.stderr)
        print("No files modified. The live source may be in another project or use a different register table.", file=sys.stderr)
        return 3
    for path, raw, old, new, notes in eligible:
        print(f"\nTARGET: {path}")
        for note in notes:
            print(f"  - {note}")
        if args.dry_run:
            print("".join(difflib.unified_diff(old.splitlines(True), new.splitlines(True),
                    fromfile=str(path), tofile=str(path))).rstrip())
            continue
        stamp = datetime.now().strftime("%Y%m%d_%H%M%S")
        backup = path.with_name(path.name + f".backup_{stamp}")
        backup.write_bytes(raw)
        # Keep BOM and newline conventions from the original source.
        bom = b"\xef\xbb\xbf" if raw.startswith(b"\xef\xbb\xbf") else b""
        path.write_bytes(bom + new.encode("utf-8"))
        check = path.read_bytes().decode("utf-8-sig")
        if not ENTRY_16.search(check) or ENTRY_12.search(check):
            path.write_bytes(raw)
            print("ERROR: verification failed; original content restored.", file=sys.stderr)
            return 4
        print(f"  MODIFIED. Backup: {backup}")
    if not args.dry_run:
        if (root / ".git").exists():
            subprocess.run(["git", "-C", str(root), "diff", "--check"], check=False)
        print("\nDone. Rebuild the Vitis application; no Vivado bitstream change is needed for CHAN_NUM.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
