import sys

import numpy as np
import onnxruntime as ort


def make_feed(sess, rng):
    feed = {}
    for inp in sess.get_inputs():
        shape = tuple(d if isinstance(d, int) else 1 for d in inp.shape)
        if 'mask' in inp.name.lower():
            arr = np.zeros(shape, dtype=np.float32)
        else:
            arr = (rng.rand(*shape).astype(np.float32) * 2.0 - 0.5)
        feed[inp.name] = arr
    return feed


def main():
    quant_path, fp32_path = sys.argv[1], sys.argv[2]
    rng = np.random.RandomState(0)
    sq = ort.InferenceSession(quant_path, providers=['CPUExecutionProvider'])
    sf = ort.InferenceSession(fp32_path, providers=['CPUExecutionProvider'])
    fq = make_feed(sq, rng)
    ff = {}
    for inp in sf.get_inputs():
        assert inp.name in fq, f'input {inp.name} missing in quant model'
        ff[inp.name] = fq[inp.name]
    oq = sq.run(None, fq)
    of = sf.run(None, ff)
    assert len(oq) == len(of)
    ok = True
    for i, (a, b) in enumerate(zip(oq, of)):
        d = np.abs(a.astype(np.float64) - b.astype(np.float64))
        mse = float(np.mean(d ** 2))
        peak = float(max(np.abs(a).max(), 1e-9))
        psnr = 10 * np.log10(peak * peak / max(mse, 1e-18))
        print(f'out[{i}] shape={a.shape} max_abs_diff={d.max():.6f} mean_abs_diff={d.mean():.6f} psnr={psnr:.2f}dB')
        if d.max() > 0.25 or psnr < 25:
            ok = False
    print('RESULT:', 'PASS' if ok else 'FAIL')


if __name__ == '__main__':
    main()
