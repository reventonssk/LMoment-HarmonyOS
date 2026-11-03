# Repro variant: replace Reshape6D->Transpose6D->Reshape4D with SpaceToDepth(4).
# Verified equivalent: the chain maps channel index to c*16 + h_in*4 + w_in,
# which is exactly ONNX SpaceToDepth blocksize=4 semantics.
import onnx
from onnx import helper, TensorProto

DST = r'D:\AI\deveco-code\LMoment\.cache\mswork\m9fb\repro_std.onnx'

nodes = [
    helper.make_node('SpaceToDepth', ['rgb'], ['pu'], name='std', blocksize=4),
    helper.make_node('AveragePool', ['mask'], ['ap'], name='ap',
                     kernel_shape=[4, 4], strides=[4, 4], pads=[0, 0, 0, 0]),
    helper.make_node('Concat', ['pu', 'ap'], ['cat'], name='node_cat', axis=1),
]

graph = helper.make_graph(
    nodes, 'repro_std',
    [helper.make_tensor_value_info('rgb', TensorProto.FLOAT, ['N', 3, 864, 1120]),
     helper.make_tensor_value_info('mask', TensorProto.FLOAT, ['N', 1, 864, 1120])],
    [helper.make_tensor_value_info('cat', TensorProto.FLOAT, ['N', 49, 216, 280])])
model = helper.make_model(graph, opset_imports=[helper.make_opsetid('', 18)])
onnx.checker.check_model(model)
onnx.save(model, DST)
print(DST)
