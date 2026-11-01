import collections
import glob
import os

import onnx

ELEM = {
    0: 'undefined', 1: 'float32', 2: 'uint8', 3: 'int8', 4: 'uint16',
    5: 'int16', 6: 'int32', 7: 'int64', 9: 'bool', 10: 'float16',
    11: 'float64', 12: 'uint32', 13: 'uint64',
}


def shape_of(v):
    t = v.type.tensor_type
    dims = [d.dim_value if d.dim_value else (d.dim_param or '?') for d in t.shape.dim]
    return f"{v.name}:{ELEM.get(t.elem_type, t.elem_type)}{dims}"


for path in sorted(glob.glob(r'D:\AI\deveco-code\LMoment\models-src\*.onnx')):
    m = onnx.load(path, load_external_data=False)
    g = m.graph
    cnt = collections.Counter(n.op_type for n in g.node)
    print('=' * 72)
    print(os.path.basename(path), f'({os.path.getsize(path)} bytes)')
    print('  ir_version:', m.ir_version, ' opset:', [(o.domain or 'ai.onnx', o.version) for o in m.opset_import])
    print('  inputs :', [shape_of(v) for v in g.input])
    print('  outputs:', [shape_of(v) for v in g.output])
    inits = len(g.initializer)
    print(f'  nodes: {len(g.node)}  initializers: {inits}')
    print('  ops:', dict(cnt.most_common()))
