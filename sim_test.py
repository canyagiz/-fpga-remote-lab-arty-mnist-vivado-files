import numpy as np, os
os.chdir(r"C:\Users\iremg\mnist_cnn")

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

base = r"artyz7_cnn_lab\artyz7_cnn_lab.sim\sim_1\behav\xsim"
w1  = load_mem_int8(f"{base}/conv2d_int8_weights.mem")
b1  = load_mem_int32(f"{base}/conv2d_int8_bias.mem")
w2  = load_mem_int8(f"{base}/conv2d_1_int8_weights.mem")
b2  = load_mem_int32(f"{base}/conv2d_1_int8_bias.mem")
wf1 = load_mem_int8(f"{base}/dense_int8_weights.mem")
bf1 = load_mem_int32(f"{base}/dense_int8_bias.mem")
wf2 = load_mem_int8(f"{base}/dense_1_int8_weights.mem")
bf2 = load_mem_int32(f"{base}/dense_1_int8_bias.mem")

def sim_conv2d(fmap_flat,in_h,in_w,in_ch,out_ch,w_flat,b_i32,shift):
    fmap=fmap_flat.reshape(in_h,in_w,in_ch).astype(np.int64)
    w=w_flat.astype(np.int64).reshape(out_ch,in_ch,3,3)
    oh,ow=in_h-2,in_w-2
    acc=np.zeros((oh,ow,out_ch),dtype=np.int64)
    for kh in range(3):
        for kw in range(3):
            patch=fmap[kh:kh+oh,kw:kw+ow,:]
            acc+=np.einsum('hwi,oi->hwo',patch,w[:,:,kh,kw])
    acc+=b_i32[np.newaxis,np.newaxis,:].astype(np.int64)
    return np.clip(acc>>shift,-128,127).reshape(-1).astype(np.int8)

def sim_relu(x): return np.maximum(0,x).astype(np.int8)

def sim_maxpool(f,in_h,in_w,in_ch):
    fm=f.reshape(in_h,in_w,in_ch)
    oh,ow=in_h//2,in_w//2
    return np.maximum(np.maximum(fm[0:2*oh:2,0:2*ow:2,:],fm[1:2*oh:2,0:2*ow:2,:]),
                      np.maximum(fm[0:2*oh:2,1:2*ow:2,:],fm[1:2*oh:2,1:2*ow:2,:])).reshape(-1).astype(np.int8)

def sim_fc(f,in_sz,out_sz,w_flat,b_i32,shift):
    x=f.astype(np.int64)
    w=w_flat.astype(np.int64).reshape(out_sz,in_sz)
    return np.clip((w@x+b_i32.astype(np.int64))>>shift,-128,127).astype(np.int8)

for d in range(10):
    img = load_img(f"test_images/digit_{d}_input.mem")
    f = sim_conv2d(img,28,28,1,8,w1,b1,8)
    f = sim_relu(f)
    f = sim_maxpool(f,26,26,8)
    f = sim_conv2d(f,13,13,8,16,w2,b2,8)
    f = sim_relu(f)
    f = sim_maxpool(f,11,11,16)
    f = sim_fc(f,400,128,wf1,bf1,10)
    f = sim_relu(f)
    f = sim_fc(f,128,10,wf2,bf2,13)
    pred = int(np.argmax(f))
    status = "PASS" if pred==d else "FAIL"
    print(f"[{status}] digit={d}  predicted={pred}  scores={f.tolist()}")
