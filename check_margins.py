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

def run(img):
    f=relu(sim_conv2d(img,28,28,1,8,w1,b1,8)); f=pool(f,26,26,8)
    f=relu(sim_conv2d(f,13,13,8,16,w2,b2,8)); f=pool(f,11,11,16)
    f=relu(fc(f,400,128,wf1,bf1,10))
    return fc(f,128,10,wf2,bf2,13)

print('Mevcut test gorsellerinin INT8 skor marjlari:')
for d in range(10):
    img=load_img(f'test_images/digit_{d}_input.mem')
    sc=run(img).tolist()
    srt=sorted(enumerate(sc),key=lambda x:-x[1])
    wi,ws=srt[0]; si,ss=srt[1]
    status='OK' if wi==d else 'FAIL'
    print(f'  digit={d}: kazanan={wi}(skor={ws}) 2.={si}(skor={ss}) MARJ={ws-ss} [{status}]')
