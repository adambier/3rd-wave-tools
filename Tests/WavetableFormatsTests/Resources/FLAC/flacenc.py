"""A small FLAC encoder (RFC 9639) for making test files that ffmpeg cannot: 8/12/20/32-bit,
wasted bits, variable block sizes, Rice2 and escaped partitions, chosen stereo modes, custom
metadata blocks, and missing or wrong MD5 signatures. Not optimised; correctness only."""
import hashlib, struct

class Bits:
    def __init__(self): self.buf = bytearray(); self.acc = 0; self.n = 0
    def write(self, v, n):
        if n == 0: return
        self.acc = (self.acc << n) | (v & ((1 << n) - 1)); self.n += n
        while self.n >= 8:
            self.n -= 8; self.buf.append((self.acc >> self.n) & 0xFF)
        self.acc &= (1 << self.n) - 1 if self.n else 0
    def signed(self, v, n): self.write(v & ((1 << n) - 1), n)
    def unary(self, q): self.write(0, q); self.write(1, 1)
    def align(self):
        if self.n: self.write(0, 8 - self.n)
    def bytes(self): self.align(); return bytes(self.buf)

def crc8(data):
    c = 0
    for b in data:
        c ^= b
        for _ in range(8): c = ((c << 1) ^ 0x07) & 0xFF if c & 0x80 else (c << 1) & 0xFF
    return c

def crc16(data):
    c = 0
    for b in data:
        c ^= b << 8
        for _ in range(8): c = ((c << 1) ^ 0x8005) & 0xFFFF if c & 0x8000 else (c << 1) & 0xFFFF
    return c

def utf8num(n):
    if n < 0x80: return bytes([n])
    for k in range(1, 7):
        if n < (1 << (5 * k + 6)):
            first = ((0xFF << (7 - k)) & 0xFF) | (n >> (6 * k))
            return bytes([first] + [0x80 | ((n >> (6 * (k - 1 - i))) & 0x3F) for i in range(k)])
    raise ValueError

BLOCK_CODES = {192: 1, 576: 2, 1152: 3, 2304: 4, 4608: 5, 256: 8, 512: 9, 1024: 10, 2048: 11, 4096: 12, 8192: 13, 16384: 14, 32768: 15}
RATE_CODES = {88200: 1, 176400: 2, 192000: 3, 8000: 4, 16000: 5, 22050: 6, 24000: 7, 32000: 8, 44100: 9, 48000: 10, 96000: 11}
SIZE_CODES = {8: 1, 12: 2, 16: 4, 20: 5, 24: 6, 32: 7}

def rice_partition(w, residual, param_bits):
    """Writes one partition's samples with the best Rice parameter, escaping when it is too wide."""
    escape = (1 << param_bits) - 1
    best = None
    for p in range(0, escape):
        bits = sum(((((r << 1) ^ (r >> 63)) if r >= 0 else ((-r << 1) - 1)) >> p) + 1 + p for r in residual)
        if best is None or bits < best[1]: best = (p, bits)
    maxabs = max((abs(r) for r in residual), default=0)
    raw = max(1, maxabs.bit_length() + 1) if residual else 1
    if best is None or best[1] > len(residual) * raw + 5 or raw > 31 and False:
        pass
    if best[1] > len(residual) * raw:
        w.write(escape, param_bits); w.write(raw, 5)
        for r in residual: w.signed(r, raw)
    else:
        p = best[0]; w.write(p, param_bits)
        for r in residual:
            u = (r << 1) if r >= 0 else ((-r << 1) - 1)
            w.unary(u >> p); w.write(u & ((1 << p) - 1), p)

def write_residual(w, residual, n, order, method=0, partition_order=0, escape_zero=False):
    w.write(method, 2); w.write(partition_order, 4)
    parts = 1 << partition_order
    per = n >> partition_order
    param_bits = 4 if method == 0 else 5
    i = 0
    for p in range(parts):
        end = (p + 1) * per - order
        seg = residual[i:end]; i = end
        if escape_zero and all(r == 0 for r in seg):
            w.write((1 << param_bits) - 1, param_bits); w.write(0, 5)
        else:
            rice_partition(w, seg, param_bits)

def subframe(w, samples, bps, kind, wasted=0, lpc=None, method=0, partition_order=0, escape_zero=False):
    """kind: 'constant', 'verbatim', ('fixed', order), or 'lpc' with lpc=(coefs, precision, shift)."""
    w.write(0, 1)
    s = [v >> wasted for v in samples]
    depth = bps - wasted
    n = len(s)
    if kind == 'constant':
        w.write(0, 6)
    elif kind == 'verbatim':
        w.write(1, 6)
    elif kind[0] == 'fixed':
        w.write(8 + kind[1], 6)
    else:
        w.write(32 + len(lpc[0]) - 1, 6)
    if wasted: w.write(1, 1); w.unary(wasted - 1)
    else: w.write(0, 1)
    if kind == 'constant':
        assert all(v == s[0] for v in s); w.signed(s[0], depth)
    elif kind == 'verbatim':
        for v in s: w.signed(v, depth)
    elif kind[0] == 'fixed':
        order = kind[1]
        for v in s[:order]: w.signed(v, depth)
        res = []
        for i in range(order, n):
            pred = {0: 0, 1: s[i-1], 2: 2*s[i-1]-s[i-2], 3: 3*s[i-1]-3*s[i-2]+s[i-3], 4: 4*s[i-1]-6*s[i-2]+4*s[i-3]-s[i-4]}[order]
            res.append(s[i] - pred)
        write_residual(w, res, n, order, method, partition_order, escape_zero)
    else:
        coefs, precision, shift = lpc; order = len(coefs)
        for v in s[:order]: w.signed(v, depth)
        w.write(precision - 1, 4); w.signed(shift, 5)
        for c in coefs: w.signed(c, precision)
        res = []
        for i in range(order, n):
            pred = sum(coefs[j] * s[i-1-j] for j in range(order)) >> shift
            res.append(s[i] - pred)
        write_residual(w, res, n, order, method, partition_order, escape_zero)

def frame(channels, bps, rate, number, variable, mode, kinds, wasted=0, **kw):
    """channels: list of per-channel sample lists (the real left/right...). mode: 0 independent,
    8 left/side, 9 right/side, 10 mid/side. kinds: per encoded channel, see subframe."""
    n = len(channels[0]); w = Bits()
    w.write(0x7FFC, 15); w.write(1 if variable else 0, 1)
    bc = BLOCK_CODES.get(n); w.write(bc if bc else (6 if n <= 256 else 7), 4)
    rc = RATE_CODES.get(rate)
    if rc is None and rate % 1000 == 0 and rate // 1000 < 256: rc, rv, rb = 12, rate // 1000, 8
    elif rc is None and rate < 65536: rc, rv, rb = 13, rate, 16
    elif rc is None: rc, rv, rb = 14, rate // 10, 16
    else: rv = None
    w.write(rc, 4)
    w.write(mode if mode else len(channels) - 1, 4)
    w.write(SIZE_CODES[bps], 3); w.write(0, 1)
    for b in utf8num(number): w.write(b, 8)
    if not bc: w.write(n - 1, 8 if n <= 256 else 16)
    if rv is not None: w.write(rv, rb)
    hdr = w.bytes(); hdr += bytes([crc8(hdr)])
    w = Bits(); w.buf = bytearray(hdr)
    enc = list(channels)
    if mode == 8: enc = [channels[0], [l - r for l, r in zip(*channels)]]
    elif mode == 9: enc = [[l - r for l, r in zip(*channels)], channels[1]]
    elif mode == 10: enc = [[(l + r) >> 1 for l, r in zip(*channels)], [l - r for l, r in zip(*channels)]]
    for c, (samples, kind) in enumerate(zip(enc, kinds)):
        side = (mode == 8 and c == 1) or (mode == 9 and c == 0) or (mode == 10 and c == 1)
        k = dict(kw); 
        if isinstance(kind, dict): k.update(kind); kind = k.pop('kind')
        subframe(w, samples, bps + (1 if side else 0), kind, wasted=wasted if not side else 0, **k)
    body = w.bytes()
    return body + struct.pack('>H', crc16(body))

def streaminfo(minb, maxb, minf, maxf, rate, nch, bps, total, md5):
    x = (rate << 44) | ((nch - 1) << 41) | ((bps - 1) << 36) | total
    return struct.pack('>HH', minb, maxb) + minf.to_bytes(3, 'big') + maxf.to_bytes(3, 'big') + x.to_bytes(8, 'big') + md5

def block(t, body, last): return bytes([t | (0x80 if last else 0)]) + len(body).to_bytes(3, 'big') + body

def vorbis(fields, vendor=b'test'):
    out = struct.pack('<I', len(vendor)) + vendor + struct.pack('<I', len(fields))
    for f in fields: out += struct.pack('<I', len(f)) + f
    return out

def encode(channels, bps, rate, blocks, kinds, mode=0, variable=False, md5='right', extra_blocks=(), wasted=0, **kw):
    """channels: per-channel full sample lists. blocks: list of block sizes partitioning the audio.
    kinds: per block, the per-channel subframe kinds. extra_blocks: (type, body) metadata blocks."""
    nch = len(channels); total = len(channels[0])
    bpsample = (bps + 7) // 8
    raw = bytearray()
    for i in range(total):
        for c in channels: raw += (c[i] & ((1 << (8 * bpsample)) - 1)).to_bytes(bpsample, 'little')
    sig = hashlib.md5(raw).digest()
    if md5 == 'none': sig = bytes(16)
    elif md5 == 'wrong': sig = bytes([sig[0] ^ 1]) + sig[1:]
    frames = []; pos = 0
    for k, n in enumerate(blocks):
        frames.append(frame([c[pos:pos+n] for c in channels], bps, rate, pos if variable else k, variable, mode, kinds[k], wasted=wasted, **kw))
        pos += n
    assert pos == total
    out = b'fLaC' + block(0, streaminfo(min(blocks), max(blocks), min(map(len, frames)), max(map(len, frames)), rate, nch, bps, total, sig), not extra_blocks)
    for i, (t, body) in enumerate(extra_blocks): out += block(t, body, i == len(extra_blocks) - 1)
    return out + b''.join(frames)
