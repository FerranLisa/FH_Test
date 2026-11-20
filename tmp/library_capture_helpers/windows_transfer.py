import os, sys, runpy
from pathlib import Path
# Preserve Library metadata as NTFS alternate data streams on Windows.
os.setxattr=lambda path,name,value: Path(str(path)+':'+os.fsdecode(name)).write_bytes(value)
os.getxattr=lambda path,name: Path(str(path)+':'+os.fsdecode(name)).read_bytes()
runpy.run_path('tmp/library_capture_helpers/library_file_transfer.py',run_name='__main__')
