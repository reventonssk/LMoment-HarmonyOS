# Bake static batch=2 into m9fb_colorfix.onnx (app runs BATCH=2 tiles).
# Same MS 2.3.1 issue as styletrans: dynamic 'N' batch forces runtime resize
# which re-runs InferShape on the broken converted graph (node_conv2d fails).
import onnx

SRC = r'D:\AI\deveco-code\LMoment\models-src\m9fb_colorfix.onnx'
DST = r'D:\AI\deveco-code\LMoment\.cache\mswork\m9fb\m9fb_colorfix_b2.onnx'

m = onnx.load(SRC)
for inp in m.graph.input:
    dims = inp.type.tensor_type.shape.dim
    if len(dims) == 4:
        if not dims[0].HasField('dim_value') or dims[0].dim_value < 0:
            dims[0].Clear()
            dims[0].dim_value = 2
            print(f'fixed batch=2 on input {inp.name}')

m = onnx.shape_inference.infer_shapes(m)
onnx.checker.check_model(m)
onnx.save(m, DST)
print(f'-> {DST}')
