"""Draws the Valentine icon (a bold V on a dark rounded tile) with the standard library only.

Writes valentine.ico (PNG-compressed frames, 16-256 px) and valentine.png (256 px) next to
this script. Run: python make_icon.py
"""
import os
import struct
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
SIZES = [16, 20, 24, 32, 40, 48, 64, 128, 256]
SS = 4  # supersampling per axis, for anti-aliased edges

TILE_RADIUS = 0.22
TILE_TOP, TILE_BOTTOM = (0x22, 0x1b, 0x24), (0x10, 0x0d, 0x12)
V_TOP, V_BOTTOM = (0xff, 0x6b, 0x9a), (0xe0, 0x1e, 0x5a)
# The V as one concave polygon in unit coordinates (x right, y down).
V_SHAPE = [(0.17, 0.22), (0.375, 0.22), (0.50, 0.585), (0.625, 0.22),
           (0.83, 0.22), (0.585, 0.81), (0.415, 0.81)]


def inside_tile(x, y):
    r = TILE_RADIUS
    cx = min(max(x, r), 1 - r)
    cy = min(max(y, r), 1 - r)
    return (x - cx) ** 2 + (y - cy) ** 2 <= r * r


def inside_v(x, y):
    hit = False
    n = len(V_SHAPE)
    for i in range(n):
        x1, y1 = V_SHAPE[i]
        x2, y2 = V_SHAPE[(i + 1) % n]
        if (y1 > y) != (y2 > y) and x < (x2 - x1) * (y - y1) / (y2 - y1) + x1:
            hit = not hit
    return hit


def mix(a, b, t):
    return tuple(round(a[i] + (b[i] - a[i]) * t) for i in range(3))


def render(size):
    rows = []
    for py in range(size):
        row = bytearray([0])  # PNG filter: none
        for px in range(size):
            tile = v = 0
            for sy in range(SS):
                for sx in range(SS):
                    x = (px + (sx + 0.5) / SS) / size
                    y = (py + (sy + 0.5) / SS) / size
                    if inside_tile(x, y):
                        tile += 1
                        v += inside_v(x, y)
            t = (py + 0.5) / size
            bg = mix(TILE_TOP, TILE_BOTTOM, t)
            fg = mix(V_TOP, V_BOTTOM, t)
            k = v / tile if tile else 0
            rgb = mix(bg, fg, k)
            row += bytes(rgb) + bytes([round(255 * tile / (SS * SS))])
        rows.append(bytes(row))
    return png(size, b''.join(rows))


def png(size, raw):
    def chunk(kind, data):
        body = kind + data
        return struct.pack('>I', len(data)) + body + struct.pack('>I', zlib.crc32(body))
    ihdr = struct.pack('>IIBBBBB', size, size, 8, 6, 0, 0, 0)  # 8-bit RGBA
    return b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', ihdr) + chunk(b'IDAT', zlib.compress(raw, 9)) + chunk(b'IEND', b'')


def ico(frames):
    header = struct.pack('<HHH', 0, 1, len(frames))
    offset = 6 + 16 * len(frames)
    entries, blobs = b'', b''
    for size, data in frames:
        dim = 0 if size >= 256 else size  # 0 means 256 in an ICO directory
        entries += struct.pack('<BBBBHHII', dim, dim, 0, 0, 1, 32, len(data), offset)
        blobs += data
        offset += len(data)
    return header + entries + blobs


if __name__ == '__main__':
    frames = [(s, render(s)) for s in SIZES]
    with open(os.path.join(HERE, 'valentine.ico'), 'wb') as f:
        f.write(ico(frames))
    with open(os.path.join(HERE, 'valentine.png'), 'wb') as f:
        f.write(frames[-1][1])
    print('wrote valentine.ico and valentine.png')
