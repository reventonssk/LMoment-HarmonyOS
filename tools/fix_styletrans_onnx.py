# Replace Resize(nearest, 2x) nodes in m9fb_styletrans_high.onnx with
# mathematically equivalent ConvTranspose(group=C, 2x2 all-ones kernel, stride 2).
# converter_lite 2.3.1 mis-compiles the Resize nodes (runtime Concat InferShape
# mismatch on device and PC benchmark), while ConvTranspose converts reliably.
# Nearest 2x upsample: each input pixel replicates into a 2x2 output block,
# which equals ConvTranspose with per-channel 2x2 ones kernel, stride 2, no pad.
import onnx
from onnx import helper, TensorProto, numpy_helper
import numpy as np

SRC = r'D:\AI\deveco-code\LMoment\models-src\m9fb_styletrans_high.onnx'
DST = r'D:\AI\deveco-code\LMoment\.cache\mswork\m9fb\m9fb_styletrans_high_ct.onnx'

m = onnx.load(SRC)
g = m.graph

vis = {vi.name: vi for vi in list(g.value_info)}
for o in g.output:
    vis[o.name] = o

new_nodes = []
removed = 0
for n in g.node:
    if n.op_type == 'Resize':
        x_name = n.input[0]
        out_name = n.output[0]
        # channel count from producer's value_info if present
        chans = 32
        vi = vis.get(x_name)
        if vi is not None:
            dims = [d.dim_value if d.HasField('dim_value') else -1
                    for d in vi.type.tensor_type.shape.dim]
            if len(dims) == 4 and dims[1] > 0:
                chans = dims[1]
        w_name = f'w_up2x_{removed}'
        w = numpy_helper.from_array(
            np.ones((chans, 1, 2, 2), dtype=np.float32), w_name)
        g.initializer.append(w)
        ct = helper.make_node(
            'ConvTranspose', [x_name, w_name], [out_name],
            name=f'node_ct_up2x_{removed}',
            group=chans, kernel_shape=[2, 2], strides=[2, 2],
            pads=[0, 0, 0, 0], dilations=[1, 1])
        new_nodes.append(ct)
        removed += 1
        print(f'replaced {n.name} ({x_name} -> {out_name}) channels={chans}')
    else:
        new_nodes.append(n)

del g.node[:]
g.node.extend(new_nodes)

# drop now-unused scales const 'val_4042'
used = {s for n in g.node for s in list(n.input)}
keep = [i for i in g.initializer if i.name in used]
del g.initializer[:]
g.initializer.extend(keep)

onnx.checker.check_model(m)
onnx.save(m, DST)
print(f'{removed} Resize nodes replaced -> {DST}')
