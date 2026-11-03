# Minimal repro of the m9fb_styletrans_high entry pattern:
#   rgb  -> Reshape(-1,3,216,4,280,4) -> Transpose(6D) -> Reshape(-1,48,216,280)
#   mask -> AveragePool(4x4/4) -> [1,1,216,280]
#   Concat(axis=1) -> [1,49,216,280]
# Convert this with converter_lite and benchmark to isolate the MS 2.3.1 failure.
import numpy as np
import onnx
from onnx import helper, TensorProto, numpy_helper

DST = r'D:\AI\deveco-code\LMoment\.cache\mswork\m9fb\repro_entry.onnx'

s1 = numpy_helper.from_array(np.array([-1, 3, 216, 4, 280, 4], dtype=np.int64), 's1')
s2 = numpy_helper.from_array(np.array([-1, 48, 216, 280], dtype=np.int64), 's2')

nodes = [
    helper.make_node('Reshape', ['rgb', 's1'], ['v15'], name='r1'),
    helper.make_node('Transpose', ['v15'], ['v16'], name='t1', perm=[0, 1, 3, 5, 2, 4]),
    helper.make_node('Reshape', ['v16', 's2'], ['pu'], name='r2'),
    helper.make_node('AveragePool', ['mask'], ['ap'], name='ap',
                     kernel_shape=[4, 4], strides=[4, 4], pads=[0, 0, 0, 0]),
    helper.make_node('Concat', ['pu', 'ap'], ['cat'], name='node_cat', axis=1),
]

graph = helper.make_graph(
    nodes, 'repro',
    [helper.make_tensor_value_info('rgb', TensorProto.FLOAT, ['N', 3, 864, 1120]),
     helper.make_tensor_value_info('mask', TensorProto.FLOAT, ['N', 1, 864, 1120])],
    [helper.make_tensor_value_info('cat', TensorProto.FLOAT, ['N', 49, 216, 280])],
    [s1, s2])
model = helper.make_model(graph, opset_imports=[helper.make_opsetid('', 18)])
onnx.checker.check_model(model)
onnx.save(model, DST)
print(DST)
