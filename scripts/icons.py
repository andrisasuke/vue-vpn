#!/usr/bin/env python3
"""Generate local PNG/ICNS artwork without opening a graphics application."""
from pathlib import Path
import math
import struct
import subprocess
import zlib

ROOT = Path(__file__).resolve().parents[1]
ICONS = ROOT / "src-tauri/icons"

def distance(x, y, ax, ay, bx, by):
    t = max(0, min(1, ((x-ax)*(bx-ax)+(y-ay)*(by-ay))/((bx-ax)**2+(by-ay)**2)))
    return math.hypot(x-ax-t*(bx-ax), y-ay-t*(by-ay))

def png(size):
    rows = bytearray()
    lines = [(0.25,0.31,0.5,0.72),(0.5,0.72,0.75,0.31),(0.40,0.31,0.5,0.47),(0.5,0.47,0.60,0.31)]
    for y in range(size):
        rows.append(0)
        for x in range(size):
            px, py = (x+.5)/size, (y+.5)/size
            qx, qy = max(abs(px-.5)-.25,0), max(abs(py-.5)-.25,0)
            edge = math.hypot(qx,qy)-.19
            alpha = round(max(0,min(1,.5-edge*size))*255)
            mark = min(distance(px,py,*line) for line in lines) < .028
            color = (216,239,173) if mark else (29+int(py*6),78+int(py*18),58+int(py*9))
            rows.extend((*color,alpha))
    def chunk(tag,data):
        return struct.pack('>I',len(data))+tag+data+struct.pack('>I',zlib.crc32(tag+data)&0xffffffff)
    return b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('>IIBBBBB',size,size,8,6,0,0,0))+chunk(b'IDAT',zlib.compress(rows,9))+chunk(b'IEND',b'')

def main():
    ICONS.mkdir(exist_ok=True)
    iconset=ICONS/'icon.iconset';iconset.mkdir(exist_ok=True)
    for size in [16,32,128,256,512]:
        (iconset/f'icon_{size}x{size}.png').write_bytes(png(size))
        (iconset/f'icon_{size}x{size}@2x.png').write_bytes(png(size*2))
    (ICONS/'icon.png').write_bytes(png(512))
    subprocess.run(['iconutil','-c','icns',str(iconset),'-o',str(ICONS/'icon.icns')],check=True)

if __name__=='__main__':main()
