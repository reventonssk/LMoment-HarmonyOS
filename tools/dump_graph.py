import sys

import numpy as np
import onnx
from onnx import numpy_helper


def desc_arr(arr):
    s = f'dtype={arr.dtype} shape={list(arr.shape)}'
    if arr.size <= 8:
        s += f' val={arr.flatten().tolist()}'
    return s


path = sys.argv[1] if len(sys.argv) > 1 else r'D:\AI\deveco-code\LMoment\models-src\fast_span_x2.onnx'
m = onnx.load(path)
g = m.graph
print('== initializers ==')
for init in g.initializer:
    arr = numpy_helper.to_array(init)
    print(f'  {init.name}: {desc_arr(arr)}')
print('== nodes ==')
for i, n in enumerate(g.node):
    print(f'{i:03d} {n.op_type:22s} {n.name or ""}')
    print(f'      in={list(n.input)}')
    print(f'      out={list(n.output)}')
    if n.op_type == 'Constant':
        for a in n.attribute:
            if a.type == onnx.AttributeProto.TENSOR:
                arr = numpy_helper.to_array(onnx.helper.get_attribute_value(a))
                print(f'      const: {desc_arr(arr)}')
