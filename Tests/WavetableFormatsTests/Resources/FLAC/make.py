import sys, os, math, random, struct, subprocess, hashlib, wave
import numpy as np
sys.path.insert(0, os.path.dirname(__file__)); import flacenc
OUT = sys.argv[1]; os.makedirs(OUT, exist_ok=True)
FF = '/usr/local/bin/ffmpeg'
random.seed(7)

def table(frames, n, bps, amp=0.9):
    """A wavetable: frame k has k+1 harmonics of a saw, scaled to amp."""
    full = (1 << (bps - 1)) - 1
    out = []
    for k in range(frames):
        h = k + 1
        wave_ = [sum(math.sin(2 * math.pi * (m + 1) * i / n) / (m + 1) for m in range(h)) for i in range(n)]
        peak = max(abs(v) for v in wave_)
        out += [int(round(v / peak * amp * full)) for v in wave_]
    return out

def saw(n, bps, amp=1.0):
    full = (1 << (bps - 1))
    return [max(-full, min(full - 1, int(round((2 * i / n - 1) * amp * full)))) for i in range(n)]

def write_wav(path, channels, bps, rate=44100):
    bp = (bps + 7) // 8
    with wave.open(path, 'wb') as w:
        w.setnchannels(len(channels)); w.setsampwidth(bp); w.setframerate(rate)
        raw = bytearray()
        for i in range(len(channels[0])):
            for c in channels: raw += (c[i] & ((1 << (8 * bp)) - 1)).to_bytes(bp, 'little')
        w.writeframes(bytes(raw))

def ffmpeg_encode(name, channels, bps, opts, rate=44100):
    tmp = os.path.join(OUT, '_tmp.wav'); write_wav(tmp, channels, bps, rate)
    subprocess.run([FF, '-y', '-loglevel', 'error', '-i', tmp, '-metadata_header_padding', '0', *opts, os.path.join(OUT, name)], check=True)
    os.remove(tmp)

def ffmpeg_decode(path):
    r = subprocess.run([FF, '-loglevel', 'error', '-i', path, '-f', 's32le', '-'], check=True, capture_output=True)
    s = np.frombuffer(r.stdout, dtype='<i4')
    b = open(path, 'rb').read(); x = int.from_bytes(b[18:26], 'big'); nch = ((x >> 41) & 7) + 1
    return s.reshape(-1, nch), nch

def fnv(data):
    h = 0xcbf29ce484222325
    for b in data: h = ((h ^ b) * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF
    return h

expect = {}
def record(name, want_first=None, want_bps=None):
    s, nch = ffmpeg_decode(os.path.join(OUT, name))
    first = s[:, 0]
    if want_first is not None:
        got = first >> (32 - want_bps)
        assert list(got) == list(want_first), name
    f = (first.astype(np.float32) * np.float32(1 / 2**31))
    expect[name] = (len(first), nch, fnv(f.astype('<f4').tobytes()))
    print(name, os.path.getsize(os.path.join(OUT, name)), expect[name])

# --- ffmpeg-made ---
t16 = table(6, 2048, 16)
ffmpeg_encode('table6_16bit_level0.flac', [t16], 16, ['-compression_level', '0']); record('table6_16bit_level0.flac')
ffmpeg_encode('table6_16bit_level8.flac', [t16], 16, ['-compression_level', '8', '-lpc_type', 'cholesky', '-exact_rice_parameters', '1']); record('table6_16bit_level8.flac')
ffmpeg_encode('table6_16bit_fixed.flac', [t16], 16, ['-compression_level', '5', '-lpc_type', 'fixed', '-max_partition_order', '6']); record('table6_16bit_fixed.flac')
ffmpeg_encode('table3_24bit_level12.flac', [table(3, 2048, 24)], 24, ['-compression_level', '12']); record('table3_24bit_level12.flac')
noise = [random.randint(-32768, 32767) for _ in range(2048)]; noise[0] = 32767; noise[1] = -32768
ffmpeg_encode('noise1_fullscale.flac', [noise], 16, ['-compression_level', '5']); record('noise1_fullscale.flac')
ffmpeg_encode('silence4.flac', [[0] * 8192], 16, []); record('silence4.flac')
ffmpeg_encode('odd_3x2048_plus100.flac', [saw(2048, 16) * 3 + saw(100, 16)], 16, []); record('odd_3x2048_plus100.flac')
L = saw(2048, 16, 0.8) * 2; R = [int(round(20000 * math.sin(2 * math.pi * 3 * i / 2048))) for i in range(4096)]
for mode in ['indep', 'left_side', 'right_side', 'mid_side']:
    ffmpeg_encode(f'stereo2_{mode}.flac', [L, R], 16, ['-ch_mode', mode, '-compression_level', '5']); record(f'stereo2_{mode}.flac')
# 44.1k vs 96k makes no difference to the reader; one at 96 kHz for the rate code
ffmpeg_encode('table4_16bit_96k.flac', [table(4, 2048, 16)], 16, ['-compression_level', '3'], rate=96000); record('table4_16bit_96k.flac')

# --- hand-made ---
def hand(name, data, want, bps):
    open(os.path.join(OUT, name), 'wb').write(data); record(name, want, bps)

# 8-bit: 4 x 2048 = 8,192 samples (an ambiguous length), constant, verbatim, and fixed subframes
s8 = [0] * 2048 + [random.randint(-128, 127) for _ in range(2048)] + table(2, 2048, 8)
d = flacenc.encode([s8], 8, 44100, [2048] * 4, [['constant'], ['verbatim'], [('fixed', 2)], [('fixed', 4)]], partition_order=2)
hand('hand_8bit.flac', d, s8, 8)

# 12-bit, blocks of 1024, fixed orders 0, 1, 3, and an escaped all-zero partition
s12 = table(2, 1024, 12) + [0] * 1024 + saw(1024, 12, 0.5)
d = flacenc.encode([s12], 12, 48000, [1024] * 4, [[('fixed', 0)], [('fixed', 1)], [('fixed', 3)], [('fixed', 3)]], partition_order=1, escape_zero=True)
hand('hand_12bit.flac', d, s12, 12)

# 20-bit, LPC order 8 with precision 12 and shift 10, partition order 3, sample rate code 12 (50 kHz)
s20 = table(2, 2048, 20)
coefs = [1664, -832, 416, -208, 104, -52, 26, -13]
d = flacenc.encode([s20], 20, 50000, [2048] * 2, [['lpc']] * 2, lpc=(coefs, 12, 10), method=0, partition_order=3)
hand('hand_20bit_lpc.flac', d, s20, 20)

# 32-bit stereo, mid/side, Rice2, slow triangle steps so residuals stay narrow
tri = []; v = -(1 << 30); step = 1 << 20
for i in range(2048):
    tri.append(v); v += step
    if v >= (1 << 30) or v <= -(1 << 30): step = -step
R32 = [int(round((2**30) * math.sin(2 * math.pi * 5 * i / 2048))) for i in range(2048)]
d = flacenc.encode([tri, R32], 32, 44100, [1024] * 2, [[('fixed', 1), 'lpc']] * 2, mode=10, lpc=([3, -3, 1], 4, 0), method=1, partition_order=2)
hand('hand_32bit_midside.flac', d, tri, 32)

# 16-bit with 4 wasted bits, variable block sizes (1000, 1048, 2048 = 2 x 2,048), sample numbers in headers
w16 = [(v >> 4) << 4 for v in table(2, 2048, 16)]
d = flacenc.encode([w16], 16, 32000, [1000, 1048, 2048], [[('fixed', 2)], ['lpc'], [('fixed', 1)]], variable=True, wasted=4, lpc=([2, -1], 3, 0), partition_order=0)
hand('hand_wasted_variable.flac', d, w16, 16)

# left/side stereo with Phase Plant-style blocks: " mlc" (a clm chunk, id reversed), "MsHk", a comment
SL = saw(2048, 16, 0.7) * 2; SR = [int(round(12000 * math.cos(2 * math.pi * 2 * i / 2048))) for i in range(4096)]
blocks = [(4, flacenc.vorbis([b'ARTIST=Test'])), (2, b'MsHk' + struct.pack('<If', 1, 1.25)), (2, b' mlc' + b'<!>1024 00000000 wavetable (test)')]
d = flacenc.encode([SL, SR], 16, 44100, [2048] * 2, [[('fixed', 2), ('fixed', 2)]] * 2, mode=8, extra_blocks=blocks, partition_order=1)
hand('hand_stereo_sides_mlc.flac', d, SL, 16)

# right/side, 24-bit, with an "srge" block forwards (as a writer that keeps chunk ids would)
SL24 = table(2, 2048, 24); SR24 = saw(2048, 24, 0.3) * 2
blocks = [(2, b'srge' + struct.pack('<ii', 1, 1024)), (1, bytes(16))]
d = flacenc.encode([SL24, SR24], 24, 44100, [4096], [[('fixed', 3), ('fixed', 1)]], mode=9, extra_blocks=blocks, partition_order=2)
hand('hand_24bit_rightside_srge.flac', d, SL24, 24)

# no MD5 (all zero) and a wrong MD5, same audio
sm = saw(2048, 16, 0.5) * 2
hand('hand_md5_none.flac', flacenc.encode([sm], 16, 44100, [2048] * 2, [[('fixed', 1)]] * 2, md5='none'), sm, 16)
open(os.path.join(OUT, 'hand_md5_wrong.flac'), 'wb').write(flacenc.encode([sm], 16, 44100, [2048] * 2, [[('fixed', 1)]] * 2, md5='wrong'))

# comments: a Serum tag in a comment, and a comment that only mentions frames
sc = table(2, 1024, 16)
hand('comment_clm.flac', flacenc.encode([sc], 16, 44100, [2048], [[('fixed', 2)]], extra_blocks=[(4, flacenc.vorbis([b'ARTIST=Test', b'COMMENT=<!>1024 00000000 wavetable (test)']))]), sc, 16)
sf = table(3, 2048, 16)
hand('comment_frames_only.flac', flacenc.encode([sf], 16, 44100, [3072] * 2, [[('fixed', 2)]] * 2, extra_blocks=[(4, flacenc.vorbis([b'FRAMES=3']))]), sf, 16)

# a Tonverk-tagged name: 3 x 1,024 + 100, 16-bit
st = saw(1024, 16) * 3 + saw(100, 16)
hand('Pad_wt1024r.flac', flacenc.encode([st], 16, 44100, [3172], [[('fixed', 1)]]), st, 16)

total = sum(os.path.getsize(os.path.join(OUT, f)) for f in os.listdir(OUT))
print('total bytes', total)
with open(os.path.join(OUT, '_expect.txt'), 'w') as f:
    for k, (n, nch, h) in sorted(expect.items()): f.write(f'"{k}": ({n}, {nch}, 0x{h:016x}),\n')
