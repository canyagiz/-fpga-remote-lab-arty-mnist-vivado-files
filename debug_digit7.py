import numpy as np, os
os.chdir(r'C:\Users\iremg\mnist_cnn')

def load_mem_int8(path):
    return np.array([int(l.strip(),16) if int(l.strip(),16)<128 else int(l.strip(),16)-256
                     for l in open(path) if l.strip()], dtype=np.int8)
def load_mem_int32(path):
    vals=[]
    for l in open(path):
        l=l.strip()
        if not l: continue
        v=int(l,16)
        if v>=0x80000000: v-=0x100000000
        vals.append(v)
    return np.array(vals,dtype=np.int32)
def load_img(path):
    return np.array([int(l.strip(),16) if int(l.strip(),16)<128 else int(l.strip(),16)-256
                     for l in open(path) if l.strip()], dtype=np.int8)

base = r'artyz7_cnn_lab\artyz7_cnn_lab.sim\sim_1\behav\xsim'
w1 =load_mem_int8(f'{base}/conv2d_int8_weights.mem')
b1 =load_mem_int32(f'{base}/conv2d_int8_bias.mem')
w2 =load_mem_int8(f'{base}/conv2d_1_int8_weights.mem')
b2 =load_mem_int32(f'{base}/conv2d_1_int8_bias.mem')
wf1=load_mem_int8(f'{base}/dense_int8_weights.mem')
bf1=load_mem_int32(f'{base}/dense_int8_bias.mem')
wf2=load_mem_int8(f'{base}/dense_1_int8_weights.mem')
bf2=load_mem_int32(f'{base}/dense_1_int8_bias.mem')

def sim_conv2d(x,in_h,in_w,in_ch,out_ch,w,b,sh):
    fm=x.reshape(in_h,in_w,in_ch).astype(np.int64)
    ww=w.astype(np.int64).reshape(out_ch,in_ch,3,3)
    oh,ow=in_h-2,in_w-2
    acc=np.zeros((oh,ow,out_ch),dtype=np.int64)
    for kh in range(3):
        for kw in range(3):
            acc+=np.einsum('hwi,oi->hwo',fm[kh:kh+oh,kw:kw+ow,:],ww[:,:,kh,kw])
    return np.clip((acc+b)>>sh,-128,127).reshape(-1).astype(np.int8)

def relu(x): return np.maximum(0,x).astype(np.int8)
def pool(x,h,w,c):
    fm=x.reshape(h,w,c); oh,ow=h//2,w//2
    return np.maximum(np.maximum(fm[0:2*oh:2,0:2*ow:2,:],fm[1:2*oh:2,0:2*ow:2,:]),
                      np.maximum(fm[0:2*oh:2,1:2*ow:2,:],fm[1:2*oh:2,1:2*ow:2,:])).reshape(-1).astype(np.int8)
def fc(x,in_s,out_s,w,b,sh):
    ww=w.astype(np.int64).reshape(out_s,in_s)
    return np.clip((ww@x.astype(np.int64)+b.astype(np.int64))>>sh,-128,127).astype(np.int8)

img = load_img('test_images/digit_7_input.mem')

f1 = sim_conv2d(img,28,28,1,8,w1,b1,8)
f1r = relu(f1)
f2 = pool(f1r,26,26,8)
f3 = sim_conv2d(f2,13,13,8,16,w2,b2,8)
f3r = relu(f3)
f4 = pool(f3r,11,11,16)
f5 = fc(f4,400,128,wf1,bf1,10)
f5r = relu(f5)
f6 = fc(f5r,128,10,wf2,bf2,13)

print("=== DIGIT 7 DEBUG (Python INT8 sim) ===")
print(f"Conv1 out (fmap1) ilk 16: {f1[:16].tolist()}")
print(f"Pool1 out (fmap2) ilk 16: {f2[:16].tolist()}")
print(f"Conv2 out (fmap3) ilk 16: {f3[:16].tolist()}")
print(f"Pool2 out (fmap4) ilk 16: {f4[:16].tolist()}")
print(f"FC1   out (fmap5) ilk 16: {f5[:16].tolist()}")
print(f"FC2   out (fmap6) tum  10: {f6.tolist()}")
print(f"Tahmin: {int(np.argmax(f6))}")

# fmap4 (FC1 input) boyutu kontrol
print(f"\nfmap4 boyutu: {len(f4)} (beklenen: 400)")
print(f"fmap5 boyutu: {len(f5)} (beklenen: 128)")
