# Verify NHWC interface contract of converted .ms models:
# 1. Generate NHWC-transposed inputs and expected outputs via onnxruntime.
# 2. Run mslite benchmark with --inDataFile and --dumpOutputDir.
# 3. Compare dumped outputs against expected (NHWC) reference.
import os
import subprocess
import numpy as np
import onnxruntime as ort

rng = np.random.default_rng(42)
ROOT = r'D:\AI\deveco-code\LMoment'
OUT = os.path.join(ROOT, r'.cache\mswork\m9fb')
DUMP = os.path.join(OUT, 'nhwc_dump')
MSLITE = os.path.join(ROOT, r'.cache\mslite\mindspore-lite-2.3.1-win-x64')
BENCH = os.path.join(MSLITE, r'tools\benchmark\benchmark.exe')
os.makedirs(DUMP, exist_ok=True)

env = dict(os.environ)
libpaths = [os.path.join(MSLITE, p) for p in (r'runtime\lib', r'tools\converter\lib')]
env['PATH'] = os.pathsep.join(libpaths) + os.pathsep + env['PATH']

# --- styletrans: onnx NCHW reference ---
rgb = rng.standard_normal((1, 3, 864, 1120)).astype(np.float32) * 0.3
mask = np.zeros((1, 1, 864, 1120), dtype=np.float32)
s = ort.InferenceSession(os.path.join(ROOT, r'models-src\m9fb_styletrans_high.onnx'),
                         providers=['CPUExecutionProvider'])
sout = s.run(None, {'rgb': rgb, 'mask': mask})[0]
rgb_nhwc = np.ascontiguousarray(rgb.transpose(0, 2, 3, 1))
mask_nhwc = np.ascontiguousarray(mask.transpose(0, 2, 3, 1))
sout_nhwc = np.ascontiguousarray(sout.transpose(0, 2, 3, 1))
rgb_nhwc.tofile(os.path.join(OUT, 'st_rgb_nhwc.bin'))
mask_nhwc.tofile(os.path.join(OUT, 'st_mask_nhwc.bin'))
print('styletrans expected out nhwc', sout_nhwc.shape, 'std', float(sout_nhwc.std()))

r = subprocess.run([BENCH,
                    r'--modelFile=' + os.path.join(ROOT, r'entry\src\main\resources\rawfile\m9fb_styletrans_high.ms'),
                    r'--inDataFile=' + os.path.join(OUT, 'st_rgb_nhwc.bin') + ',' + os.path.join(OUT, 'st_mask_nhwc.bin'),
                    r'--loopCount=1', r'--warmUpLoopCount=0',
                    r'--dumpOutputDir=' + DUMP],
                   env=env, capture_output=True, text=True, timeout=600)
print('st bench rc=', r.returncode)
print('\n'.join([l for l in (r.stdout + r.stderr).splitlines() if 'dump' in l.lower() or 'error' in l.lower() or 'success' in l.lower()][:10]))

# find dumped output
dumped = [f for f in os.listdir(DUMP) if f.endswith('.bin') or 'output' in f.lower()]
print('dumped files:', dumped)
if dumped:
    got = np.fromfile(os.path.join(DUMP, dumped[0]), dtype=np.float32)
    exp = sout_nhwc.reshape(-1)
    if got.size == exp.size:
        diff = float(np.abs(got - exp).max())
        print('STYLETRANS NHWC max_abs_diff =', diff, 'allclose =', bool(np.allclose(got, exp, atol=1e-3)))
    else:
        print('size mismatch got', got.size, 'exp', exp.size)
