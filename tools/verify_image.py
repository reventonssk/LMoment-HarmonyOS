import sys

import numpy as np
import onnxruntime as ort
from PIL import Image


def load_crop(path, size=256):
    im = Image.open(path).convert('RGB')
    w, h = im.size
    s = min(w, h)
    im = im.crop(((w - s) // 2, (h - s) // 2, (w - s) // 2 + s, (h - s) // 2 + s)).resize((size, size), Image.BILINEAR)
    a = np.asarray(im, dtype=np.float32) / 255.0
    return a.transpose(2, 0, 1)[None]


def build_mask():
    TILE, WS, SHIFT = 256, 8, 4
    NW = (TILE // WS) ** 2
    region = np.zeros((TILE, TILE), dtype=np.int32)
    cnt = 0
    b = [0, TILE - WS, TILE - SHIFT]
    e = [TILE - WS, TILE - SHIFT, TILE]
    for h0, h1 in zip(b, e):
        for w0, w1 in zip(b, e):
            region[h0:h1, w0:w1] = cnt
            cnt += 1
    n = TILE // WS
    mw = np.zeros((NW, WS * WS), dtype=np.int32)
    for wy in range(n):
        for wx in range(n):
            blk = region[wy * WS:(wy + 1) * WS, wx * WS:(wx + 1) * WS]
            mw[wy * n + wx] = blk.reshape(-1)
    return np.where(mw[:, :, None] == mw[:, None, :], 0.0, -100.0).astype(np.float32)


def main():
    img_path, quant, fp32 = sys.argv[1], sys.argv[2], sys.argv[3]
    x = load_crop(img_path)
    sq = ort.InferenceSession(quant, providers=['CPUExecutionProvider'])
    sf = ort.InferenceSession(fp32, providers=['CPUExecutionProvider'])
    fq = {'input': x}
    ff = {'input': x}
    mask = build_mask()
    if len(sq.get_inputs()) > 1:
        fq['mask'] = mask
    if len(sf.get_inputs()) > 1:
        ff['mask'] = mask
    oq = sq.run(None, fq)[0]
    of = sf.run(None, ff)[0]
    d = np.abs(oq.astype(np.float64) - of.astype(np.float64))
    mse = float(np.mean(d ** 2))
    psnr = 10 * np.log10(1.0 / max(mse, 1e-18))
    print(f'shape={oq.shape} range_q=[{oq.min():.4f},{oq.max():.4f}] range_f=[{of.min():.4f},{of.max():.4f}]')
    print(f'max_abs_diff={d.max():.6f} mean_abs_diff={d.mean():.6f} psnr_[0,1]={psnr:.2f}dB')


if __name__ == '__main__':
    main()
