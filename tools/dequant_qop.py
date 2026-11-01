import collections
import sys

import numpy as np
import onnx
from onnx import helper, numpy_helper

INT_OPS = ('ConvInteger', 'MatMulInteger')


def main():
    src, dst = sys.argv[1], sys.argv[2]
    m = onnx.load(src)
    g = m.graph
    inits = {i.name: numpy_helper.to_array(i) for i in g.initializer}
    nodes = list(g.node)
    node_index = {id(nd): i for i, nd in enumerate(nodes)}
    producers = {}
    for nd in nodes:
        for o in nd.output:
            producers[o] = nd

    removed = set()
    replace = {}
    new_inits = {}

    def dequant_weight(q_name, zp_name, scale_name):
        q = inits[q_name].astype(np.float32)
        zp = float(inits[zp_name])
        sc = float(inits[scale_name])
        return (q - zp) * sc

    def fp32_name(q_name):
        if q_name.endswith('.weight_quantized'):
            return q_name[:-len('.weight_quantized')] + '.weight'
        return q_name + '_fp32'

    def single_consumer(tensor, op_type):
        hits = [(i, nd) for i, nd in enumerate(nodes) if tensor in nd.input and nd.op_type == op_type]
        assert len(hits) == 1, f'expected single {op_type} consumer of {tensor}, got {len(hits)}'
        return hits[0]

    def resolve_cast_mul_scale(y32, a_scale):
        cast_i, cast = single_consumer(y32, 'Cast')
        y_f = cast.output[0]
        mul_i, mul = single_consumer(y_f, 'Mul')
        k = [t for t in mul.input if t != y_f][0]
        kn = producers[k]
        assert kn is not None and kn.op_type == 'Mul', f'scale tensor {k} producer is {kn.op_type if kn else None}, not Mul'
        other_scale = [t for t in kn.input if t != a_scale][0]
        removed.update({cast_i, mul_i, node_index[id(kn)]})
        return mul.output[0], other_scale

    def resolve_bias(y_scaled):
        adds = [(i, nd) for i, nd in enumerate(nodes) if y_scaled in nd.input and nd.op_type == 'Add']
        if not adds:
            return y_scaled, None
        assert len(adds) == 1, f'bias add not unique for {y_scaled}'
        add_i, add = adds[0]
        bias_r = [t for t in add.input if t != y_scaled][0]
        out = add.output[0]
        rp = producers.get(bias_r)
        if rp is not None and rp.op_type == 'Reshape':
            bias_name = rp.input[0]
            removed.add(node_index[id(rp)])
        else:
            bias_name = bias_r
        removed.add(add_i)
        return out, bias_name

    n_int = 0
    for idx, n in enumerate(nodes):
        if n.op_type not in INT_OPS:
            continue
        n_int += 1
        assert len(n.input) == 4, f'{n.name}: {n.op_type} with {len(n.input)} inputs, expected 4'
        a_i8, w_q, a_zp, w_zp = n.input
        dql = producers[a_i8]
        assert dql is not None and dql.op_type == 'DynamicQuantizeLinear', \
            f'{n.name}: input producer is {dql.op_type if dql else None}'
        a = dql.input[0]
        a_scale = dql.output[1]
        assert a_zp == dql.output[2], f'{n.name}: x_zero_point mismatch'
        removed.add(node_index[id(dql)])
        y32 = n.output[0]
        y_scaled, w_scale = resolve_cast_mul_scale(y32, a_scale)
        W = dequant_weight(w_q, w_zp, w_scale)
        W_name = fp32_name(w_q)
        new_inits[W_name] = W
        if n.op_type == 'ConvInteger':
            out, bias_name = resolve_bias(y_scaled)
            assert bias_name is not None, f'{n.name}: conv without bias'
            bias = inits[bias_name]
            assert bias.ndim == 1, f'{n.name}: bias ndim {bias.ndim}'
            inputs = [a, W_name, bias_name]
            new_node = helper.make_node('Conv', inputs, [out], name=n.name)
            new_node.attribute.extend(n.attribute)
            replace[idx] = new_node
        else:
            out, bias_name = resolve_bias(y_scaled)
            if bias_name is None:
                new_node = helper.make_node('MatMul', [a, W_name], [out], name=n.name)
            else:
                tmp = y32 + '_fp32'
                mm = helper.make_node('MatMul', [a, W_name], [tmp], name=n.name)
                ad = helper.make_node('Add', [tmp, bias_name], [out], name=n.name + '_bias')
                replace[idx] = [mm, ad]
                continue
            replace[idx] = new_node

    leftover = [nd for i, nd in enumerate(nodes)
                if i not in removed and i not in replace
                and nd.op_type in INT_OPS + ('DynamicQuantizeLinear',)]
    assert not leftover, f'unhandled int-op chains: {[nd.name for nd in leftover]}'

    final_nodes = []
    for i, nd in enumerate(nodes):
        if i in replace:
            rep = replace[i]
            if isinstance(rep, list):
                final_nodes.extend(rep)
            else:
                final_nodes.append(rep)
        elif i not in removed:
            final_nodes.append(nd)

    used = set()
    for nd in final_nodes:
        used.update(nd.input)
    for v in list(g.input) + list(g.output):
        used.add(v.name)
    kept = [i for i in g.initializer if i.name in used]
    new_protos = [numpy_helper.from_array(arr, name) for name, arr in new_inits.items()]

    del g.node[:]
    g.node.extend(final_nodes)
    del g.initializer[:]
    g.initializer.extend(kept + new_protos)
    del g.value_info[:]

    onnx.checker.check_model(m)
    onnx.save(m, dst)

    cnt_before = collections.Counter(nd.op_type for nd in nodes)
    cnt_after = collections.Counter(nd.op_type for nd in final_nodes)
    print(f'int-op groups dequantized: {n_int}')
    print(f'nodes: {len(nodes)} -> {len(final_nodes)}')
    print(f'initializers: {len(inits)} -> {len(kept) + len(new_protos)}')
    print('ops before:', dict(cnt_before.most_common()))
    print('ops after :', dict(cnt_after.most_common()))
    import os
    print('saved:', dst, os.path.getsize(dst), 'bytes')


if __name__ == '__main__':
    main()
