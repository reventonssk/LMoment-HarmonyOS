# Numerical validation: run ORIGINAL ONNX via onnxruntime on fixed random
# inputs, dump input/output bins, to be compared against converted .ms via
# benchmark --inDataFile/--benchmarkDataFile.
import numpy as np
import onnxruntime as ort

rng = np.random.default_rng(42)
OUT = r'D:\AI\deveco-code\LMoment\.cache\mswork\m9fb'

# --- styletrans: rgb [1,3,864,1120], mask [1,1,864,1120] ---
rgb = rng.standard_normal((1, 3, 864, 1120)).astype(np.float32) * 0.3
mask = np.zeros((1, 1, 864, 1120), dtype=np.float32)
s = ort.InferenceSession(r'D:\AI\deveco-code\LMoment\models-src\m9fb_styletrans_high.onnx',
                         providers=['CPUExecutionProvider'])
sout = s.run(None, {'rgb': rgb, 'mask': mask})[0]
rgb.tofile(rf'{OUT}\st_rgb.bin')
mask.tofile(rf'{OUT}\st_mask.bin')
sout.tofile(rf'{OUT}\st_out.bin')
print('styletrans out', sout.shape, 'mean', float(sout.mean()), 'std', float(sout.std()))

# --- colorfix: x [2,6,544,544] ---
x = rng.standard_normal((2, 6, 544, 544)).astype(np.float32) * 0.3
c = ort.InferenceSession(r'D:\AI\deveco-code\LMoment\models-src\m9fb_colorfix.onnx',
                         providers=['CPUExecutionProvider'])
cout = c.run(None, {'x': x})[0]
x.tofile(rf'{OUT}\cf_x.bin')
cout.tofile(rf'{OUT}\cf_out.bin')
print('colorfix out', cout.shape, 'mean', float(cout.mean()), 'std', float(cout.std()))
