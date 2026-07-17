import tensorflow as tf
import numpy as np

model = tf.keras.models.load_model('mnist_cnn_model.keras')
(_, _), (x_test, y_test) = tf.keras.datasets.mnist.load_data()

x_test_f = x_test.astype('float32') / 255.0

print("Float32 model tahminleri (her rakamdan ilk MNIST test örneği):")
for digit in range(10):
    idx = np.where(y_test == digit)[0][0]
    img = x_test_f[idx]
    pred = int(np.argmax(model.predict(img.reshape(1,28,28,1), verbose=0)))
    print(f"  digit_{digit}: tahmin={pred} {'✓' if pred==digit else '✗'}")

    import math

# ── Reproduce INT8 simulator from train.py with Verilog SHIFT values ──
SHIFTS = {'conv2d': 8, 'conv2d_1': 8, 'dense': 9, 'dense_1': 9}

layer_order = ['conv2d', 'conv2d_1', 'dense', 'dense_1']

def quantize_int8(w):
    s = 127.0 / np.abs(w).max()
    return np.round(w * s).astype(np.int8), s

def reorder(w):
    return w.transpose(3,2,0,1) if w.ndim==4 else w.T

hw_w, scales_d, float_b = {}, {}, {}
for layer in model.layers:
    ws = layer.get_weights()
    if not ws: continue
    w, b = ws
    q, s = quantize_int8(w)
    hw_w[layer.name] = reorder(q).flatten().astype(np.int8)
    scales_d[layer.name] = s
    float_b[layer.name] = b.astype(np.float64)

biases = {}
S_in = 127.0
for name in layer_order:
    sw = scales_d[name]; sh = SHIFTS[name]
    biases[name] = np.round(float_b[name] * S_in * sw).astype(np.int32)
    S_in = S_in * sw / (2**sh)

def conv2d_sim(x, h, w, ci, co, wf, b, sh):
    fm = x.reshape(h,w,ci).astype(np.int64)
    ww = wf.astype(np.int64).reshape(co,ci,3,3)
    oh,ow = h-2,w-2
    acc = np.zeros((oh,ow,co),dtype=np.int64)
    for kh in range(3):
        for kw in range(3):
            acc += np.einsum('hwi,oi->hwo', fm[kh:kh+oh,kw:kw+ow,:], ww[:,:,kh,kw])
    acc += b[np.newaxis,np.newaxis,:].astype(np.int64)
    return np.clip(acc>>sh,-128,127).reshape(-1).astype(np.int8)

def pool_sim(x, h, w, c):
    fm = x.reshape(h,w,c); oh,ow=h//2,w//2
    return np.maximum(
        np.maximum(fm[0:2*oh:2, 0:2*ow:2], fm[1:2*oh:2, 0:2*ow:2]),
        np.maximum(fm[0:2*oh:2, 1:2*ow:2], fm[1:2*oh:2, 1:2*ow:2])
    ).reshape(-1).astype(np.int8)

def fc_sim(x, ni, no, wf, b, sh):
    acc = wf.astype(np.int64).reshape(no,ni) @ x.astype(np.int64) + b.astype(np.int64)
    return np.clip(acc>>sh,-128,127).astype(np.int8)

def relu(x): return np.maximum(0,x).astype(np.int8)

def infer_int8(img_uint8_flat):
    n = layer_order
    f = conv2d_sim(img_uint8_flat,28,28,1,8,hw_w[n[0]],biases[n[0]],SHIFTS[n[0]])
    f = pool_sim(relu(f),26,26,8)
    f = conv2d_sim(f,13,13,8,16,hw_w[n[1]],biases[n[1]],SHIFTS[n[1]])
    f = pool_sim(relu(f),11,11,16)
    f = fc_sim(f,400,128,hw_w[n[2]],biases[n[2]],SHIFTS[n[2]])
    f = fc_sim(relu(f),128,10,hw_w[n[3]],biases[n[3]],SHIFTS[n[3]])
    return int(np.argmax(f))

print("\nINT8 simülatör tahminleri (Verilog SHIFT=8,8,9,9):")
for digit in range(10):
    idx = np.where(y_test==digit)[0][0]
    img_q = np.round(x_test_f[idx].squeeze()*127).astype(np.uint8).flatten()
    pred = infer_int8(img_q)
    print(f"  digit_{digit}: tahmin={pred} {'✓' if pred==digit else '✗'}")