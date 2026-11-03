# Bake static batch=1 into m9fb_styletrans_high.onnx graph inputs.
# The graph's entry Concat (node_cat) fails MS_LITE InferShape when batch is
# dynamic ('N' dim_param), through the 6-D Reshape/Transpose pixel-unshuffle.
# The app always runs this model at batch 1 (resize to [1,3,864,1120]),
# so a static batch is semantically identical and converts far more reliably.
import onnx

SRC = r'D:\AI\deveco-code\LMoment\models-src\m9fb_styletrans_high.onnx'
DST = r'D:\AI\deveco-code\LMoment\.cache\mswork\m9fb\m9fb_styletrans_high_b1.onnx'

m = onnx.load(SRC)
for inp in m.graph.input:
    dims = inp.type.tensor_type.shape.dim
    if len(dims) == 4:
        if not dims[0].HasField('dim_value'):
            dims[0].Clear()
            dims[0].dim_value = 1
            print(f'fixed batch=1 on input {inp.name}')

# static shape inference + update value_info so no stale dynamic dims remain
m = onnx.shape_inference.infer_shapes(m)
onnx.checker.check_model(m)
onnx.save(m, DST)
print(f'-> {DST}')
