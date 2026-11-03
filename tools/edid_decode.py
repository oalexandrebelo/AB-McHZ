# Decodifica um EDID binário: python3 tools/edid_decode.py profiles/edid/<arquivo>.bin
import sys
e = open(sys.argv[1], "rb").read()
def dtd(b):
    pc = (b[0] | b[1] << 8) * 10_000
    if pc == 0: return None
    ha = b[2] | (b[4] & 0xF0) << 4; hb = b[3] | (b[4] & 0x0F) << 8
    va = b[5] | (b[7] & 0xF0) << 4; vb = b[6] | (b[7] & 0x0F) << 8
    return f"{ha}x{va}@{pc / ((ha + hb) * (va + vb)):.2f}Hz pclk={pc / 1e6:.2f}MHz"
m = e[8] << 8 | e[9]
print("mfg", "".join(chr(((m >> s) & 31) + 64) for s in (10, 5, 0)), "product", hex(e[10] | e[11] << 8),
      "year", 1990 + e[17], "edid", f"{e[18]}.{e[19]}", "ext", e[126], "size_cm", e[21], "x", e[22])
print("input:", "digital" if e[20] & 0x80 else "analog", "gamma", (e[23] + 100) / 100)
for i in range(54, 126, 18):
    d = e[i:i + 18]
    if d[0] or d[1]: print(" DTD", dtd(d)); continue
    t = d[3]
    if t == 0xFD: print(f" range V {d[5]}-{d[6]}Hz H {d[7]}-{d[8]}kHz maxpclk {d[9] * 10}MHz")
    elif t in (0xFC, 0xFF): print(" name" if t == 0xFC else " serial", d[5:].split(b"\n")[0].decode(errors="replace"))
if e[126]:
    c = e[128:256]; off = c[2]; i = 4
    print("CTA rev", c[1], "underscan" if c[3] & 0x80 else "", "YCbCr444" if c[3] & 0x20 else "", "YCbCr422" if c[3] & 0x10 else "")
    while i < off:
        tag, ln = c[i] >> 5, c[i] & 31; blk = c[i + 1:i + 1 + ln]
        if tag == 2: print(" VICs", [(v & 0x7F, "native" if v & 0x80 else "") for v in blk])
        elif tag == 3: print(" VSDB OUI", blk[:3][::-1].hex(), "maxTMDS", (blk[6] * 5 if ln > 6 else "n/a"), "MHz")
        elif tag == 1: print(" audio", blk.hex())
        elif tag == 4: print(" speaker", blk.hex())
        else: print(" block tag", tag, blk.hex())
        i += 1 + ln
    while off + 18 <= 127 and (c[off] or c[off + 1]):
        print(" CTA DTD", dtd(c[off:off + 18])); off += 18
