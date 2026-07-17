import os
import math
import tensorflow as tf
from tensorflow.keras import layers, models
import numpy as np
import matplotlib.pyplot as plt

MODEL_PATH = 'mnist_cnn_model.keras'

(x_train, y_train), (x_test, y_test) = tf.keras.datasets.mnist.load_data()

print("Eğitim görüntü sayısı:", x_train.shape)
print("Test görüntü sayısı:", x_test.shape)

plt.imshow(x_train[0], cmap='gray')
plt.title(f"Etiket: {y_train[0]}")
plt.savefig('ornek_goruntu.png')
print("Görüntü kaydedildi: ornek_goruntu.png")

x_train = x_train.astype('float32') / 255.0
x_test = x_test.astype('float32') / 255.0

x_train = x_train.reshape(-1, 28, 28, 1)
x_test = x_test.reshape(-1, 28, 28, 1)

print("Yeni eğitim verisi boyutu:", x_train.shape)
print("Piksel değer aralığı:", x_train.min(), "-", x_train.max())

if os.path.exists(MODEL_PATH):
    print(f"\nKaydedilmiş model bulundu: {MODEL_PATH} — yükleniyor...")
    model = models.load_model(MODEL_PATH)
    model.summary()
else:
    print("\nKaydedilmiş model bulunamadı — eğitim başlıyor...")
    model = models.Sequential([
        layers.Conv2D(8, (3,3), activation='relu', input_shape=(28,28,1)),
        layers.MaxPooling2D((2,2)),
        layers.Conv2D(16, (3,3), activation='relu'),
        layers.MaxPooling2D((2,2)),
        layers.Flatten(),
        layers.Dense(128, activation='relu'),
        layers.Dense(10, activation='softmax')
    ])

    model.summary()

    model.compile(
        optimizer='adam',
        loss='sparse_categorical_crossentropy',
        metrics=['accuracy']
    )

    model.fit(
        x_train, y_train,
        epochs=10,
        validation_split=0.1,
        batch_size=64
    )

    model.save(MODEL_PATH)
    print(f"Model kaydedildi: {MODEL_PATH}")

test_loss, test_acc = model.evaluate(x_test, y_test)
print(f"\nGerçek test doğruluğu: {test_acc:.4f}")
print(f"Test kaybı: {test_loss:.4f}")

for layer in model.layers:
    weights = layer.get_weights()
    if weights:
        w, b = weights
        print(f"{layer.name}: ağırlık şekli {w.shape}, bias şekli {b.shape}")
        print(f"  min: {w.min():.4f}, max: {w.max():.4f}")

def quantize_int8(weights):
    max_val = np.abs(weights).max()
    scale = 127.0 / max_val
    quantized = np.round(weights * scale).astype(np.int8)
    return quantized, scale

print("\n--- INT8 Quantizasyon ---")
quantized_weights = {}
scales = {}

for layer in model.layers:
    w = layer.get_weights()
    if w:
        weight, bias = w
        q_weight, scale = quantize_int8(weight)
        quantized_weights[layer.name] = q_weight
        scales[layer.name] = scale
        print(f"{layer.name}: scale={scale:.4f}, "
              f"quantized min={q_weight.min()}, max={q_weight.max()}")

os.makedirs('coe_files/int8', exist_ok=True)

def save_as_mem(quantized_array, filename):
    """Plain-hex .mem file for Verilog $readmemh — one byte per line, no header."""
    flat = quantized_array.flatten()
    with open(filename, 'w') as f:
        for v in flat:
            f.write(f"{int(v) & 0xFF:02X}\n")
    print(f"Kaydedildi: {filename} ({len(flat)} değer, .mem)")

def save_as_mem_int32(array, filename):
    """32-bit hex .mem file — one 8-char word per line, for int32 biases."""
    flat = np.array(array).flatten().astype(np.int64)
    with open(filename, 'w') as f:
        for v in flat:
            f.write(f"{int(v) & 0xFFFFFFFF:08X}\n")
    print(f"Kaydedildi: {filename} ({len(flat)} değer, INT32 .mem)")

def save_as_coe(quantized_array, filename):
    flat = quantized_array.flatten()
    # negatif sayıları 8-bit two's complement hex'e çevir
    hex_values = [format(int(v) & 0xFF, '02X') for v in flat]
    
    with open(filename, 'w') as f:
        f.write("memory_initialization_radix=16;\n")
        f.write("memory_initialization_vector=\n")
        f.write(",\n".join(hex_values))
        f.write(";\n")
    
    print(f"Kaydedildi: {filename} ({len(flat)} değer)")

print("\n--- Katman başına SHIFT değerleri ---")
layer_shifts = {}
for layer_name, scale in scales.items():
    shift = max(1, round(math.log2(scale)))
    layer_shifts[layer_name] = shift
    print(f"  {layer_name}: scale_w={scale:.2f}, SHIFT={shift}")

print("\n=== Verilog için SHIFT parametreleri (top_module.v) ===")
layer_order = list(layer_shifts.keys())
if len(layer_order) >= 1: print(f"  u_conv1 SHIFT={layer_shifts[layer_order[0]]}")
if len(layer_order) >= 2: print(f"  u_conv2 SHIFT={layer_shifts[layer_order[1]]}")
if len(layer_order) >= 3: print(f"  u_fc1   SHIFT={layer_shifts[layer_order[2]]}")
if len(layer_order) >= 4: print(f"  u_fc2   SHIFT={layer_shifts[layer_order[3]]}")
print("=" * 50)

def reorder_for_verilog(w):
    """Keras → Verilog bellek sırası dönüşümü.
    Conv2D: (kH,kW,C_in,C_out) → (C_out,C_in,kH,kW)
    Dense:  (in,out)            → (out,in)
    """
    if w.ndim == 4:
        return w.transpose(3, 2, 0, 1)
    elif w.ndim == 2:
        return w.T
    return w

for layer_name, q_weight in quantized_weights.items():
    q_weight_verilog = reorder_for_verilog(q_weight)
    save_as_coe(q_weight_verilog, f"coe_files/int8/{layer_name}_int8_weights.coe")
    save_as_mem(q_weight_verilog, f"coe_files/int8/{layer_name}_int8_weights.mem")

# =============================================================================
# INT8 Donanım Simülatörü + Kalibrasyon
# =============================================================================
print("\n--- INT8 Donanım Simülatörü: doğru SHIFT ve bias aranıyor ---")

# Katman sırası ve float bias'ları al
layer_order_names = list(scales.keys())  # [conv2d, conv2d_1, dense, dense_1]
float_biases = {}
for layer in model.layers:
    if layer.get_weights():
        _, b = layer.get_weights()
        float_biases[layer.name] = b.astype(np.float64)

# Verilog sırasına çevrilmiş INT8 ağırlıklar
hw_weights_flat = {}
for name, qw in quantized_weights.items():
    hw_weights_flat[name] = reorder_for_verilog(qw).flatten().astype(np.int8)

# ── Vektörel INT8 simülasyon fonksiyonları ────────────────────────────────────
def sim_conv2d(fmap_flat, in_h, in_w, in_ch, out_ch, w_flat, b_i32, shift):
    fmap = fmap_flat.reshape(in_h, in_w, in_ch).astype(np.int64)
    w    = w_flat.astype(np.int64).reshape(out_ch, in_ch, 3, 3)
    out_h, out_w = in_h - 2, in_w - 2
    acc = np.zeros((out_h, out_w, out_ch), dtype=np.int64)
    for kh in range(3):
        for kw in range(3):
            patch = fmap[kh:kh+out_h, kw:kw+out_w, :]       # (oH,oW,C_in)
            acc += np.einsum('hwi,oi->hwo', patch, w[:,:,kh,kw])
    acc += b_i32[np.newaxis, np.newaxis, :].astype(np.int64)
    acc  = np.clip(acc >> shift, -128, 127)
    return acc.reshape(-1).astype(np.int8)

def sim_relu(x):
    return np.maximum(0, x).astype(np.int8)

def sim_maxpool(fmap_flat, in_h, in_w, in_ch):
    fmap  = fmap_flat.reshape(in_h, in_w, in_ch)
    out_h, out_w = in_h // 2, in_w // 2
    # Slicing ile 2x2 max — tek boyutlu (11x11 gibi) inputlarda da çalışır
    out = np.maximum(
        np.maximum(fmap[0:2*out_h:2, 0:2*out_w:2, :],
                   fmap[1:2*out_h:2, 0:2*out_w:2, :]),
        np.maximum(fmap[0:2*out_h:2, 1:2*out_w:2, :],
                   fmap[1:2*out_h:2, 1:2*out_w:2, :])
    )
    return out.reshape(-1).astype(np.int8)

def sim_fc(fmap_flat, in_sz, out_sz, w_flat, b_i32, shift):
    x = fmap_flat.astype(np.int64)
    w = w_flat.astype(np.int64).reshape(out_sz, in_sz)
    acc = w @ x + b_i32.astype(np.int64)
    return np.clip(acc >> shift, -128, 127).astype(np.int8)

def run_pipeline(img_q_flat, shifts, biases_i32):
    n = layer_order_names
    f1 = sim_conv2d(img_q_flat, 28, 28, 1,  8,  hw_weights_flat[n[0]], biases_i32[n[0]], shifts[n[0]])
    f1 = sim_relu(f1)
    f2 = sim_maxpool(f1, 26, 26, 8)
    f3 = sim_conv2d(f2,  13, 13, 8,  16, hw_weights_flat[n[1]], biases_i32[n[1]], shifts[n[1]])
    f3 = sim_relu(f3)
    f4 = sim_maxpool(f3, 11, 11, 16)
    f5 = sim_fc(f4, 400, 128, hw_weights_flat[n[2]], biases_i32[n[2]], shifts[n[2]])
    f5 = sim_relu(f5)
    f6 = sim_fc(f5, 128,  10, hw_weights_flat[n[3]], biases_i32[n[3]], shifts[n[3]])
    return int(np.argmax(f6))

# ── Kalibrasyon veri seti: 1000 rastgele test görüntüsü (endüstri standardı
#    "calibration set" yaklaşımı — tek örneklerle değil, geniş örneklemle
#    SHIFT parametrelerini ayarla) ─────────────────────────────────────────────
rng = np.random.default_rng(42)
calib_idx = rng.choice(len(x_test), size=1000, replace=False)

calib_imgs_q = []
calib_labels = []
for i in calib_idx:
    img = x_test[i]
    calib_imgs_q.append(np.round(img.squeeze() * 127).astype(np.int8).flatten())
    calib_labels.append(int(y_test[i]))

def run_pipeline_with_margin(img_q_flat, shifts, biases_i32):
    """run_pipeline gibi ama son katman skorlarını da döndürür (marj hesabı için)."""
    n = layer_order_names
    f1 = sim_conv2d(img_q_flat, 28, 28, 1,  8,  hw_weights_flat[n[0]], biases_i32[n[0]], shifts[n[0]])
    f1 = sim_relu(f1)
    f2 = sim_maxpool(f1, 26, 26, 8)
    f3 = sim_conv2d(f2,  13, 13, 8,  16, hw_weights_flat[n[1]], biases_i32[n[1]], shifts[n[1]])
    f3 = sim_relu(f3)
    f4 = sim_maxpool(f3, 11, 11, 16)
    f5 = sim_fc(f4, 400, 128, hw_weights_flat[n[2]], biases_i32[n[2]], shifts[n[2]])
    f5 = sim_relu(f5)
    f6 = sim_fc(f5, 128,  10, hw_weights_flat[n[3]], biases_i32[n[3]], shifts[n[3]])
    return f6

# ── Grid search: conv SHIFT sabit (8,8), FC SHIFT ara ────────────────────────
# Skor fonksiyonu: doğruluk (birincil) + ortalama marj (ikincil, eşitlik bozucu).
# Marj = kazanan skor - ikinci en yüksek skor. Düşük marj = quantization
# gürültüsüne karşı kırılgan tahmin (borderline durumlarda ters dönebilir).
best_key    = (-1, -1.0)
best_shifts = None
best_biases = None

conv_shifts = {layer_order_names[0]: 8, layer_order_names[1]: 8}

for s_fc1 in range(7, 14):
    for s_fc2 in range(7, 14):
        trial_shifts = {**conv_shifts,
                        layer_order_names[2]: s_fc1,
                        layer_order_names[3]: s_fc2}

        # Bias: S_in zinciri takip et (her katmanın giriş ölçeği)
        trial_biases = {}
        S_in = 127.0
        for name in layer_order_names:
            sw   = scales[name]
            sh   = trial_shifts[name]
            trial_biases[name] = np.round(float_biases[name] * S_in * sw).astype(np.int32)
            S_in = S_in * sw / (2 ** sh)

        correct = 0
        margin_sum = 0.0
        for img_q, label in zip(calib_imgs_q, calib_labels):
            scores = run_pipeline_with_margin(img_q, trial_shifts, trial_biases)
            sorted_s = np.sort(scores.astype(np.int64))[::-1]
            pred = int(np.argmax(scores))
            margin_sum += float(sorted_s[0] - sorted_s[1])
            if pred == label:
                correct += 1

        avg_margin = margin_sum / len(calib_labels)
        key = (correct, avg_margin)

        if key > best_key:
            best_key    = key
            best_shifts = trial_shifts.copy()
            best_biases = {k: v.copy() for k, v in trial_biases.items()}
            n = layer_order_names
            print(f"  SHIFT=({trial_shifts[n[0]]},{trial_shifts[n[1]]},"
                  f"{trial_shifts[n[2]]},{trial_shifts[n[3]]}) → "
                  f"{correct}/{len(calib_labels)}  ortalama_marj={avg_margin:.3f}")

best_score = best_key[0]
print(f"\nEn iyi sonuç: {best_score}/{len(calib_labels)}  (ortalama marj={best_key[1]:.3f})")
print("=== Verilog SHIFT Parametreleri (top_module.v) ===")
vmap = {layer_order_names[0]:'u_conv1', layer_order_names[1]:'u_conv2',
        layer_order_names[2]:'u_fc1',   layer_order_names[3]:'u_fc2'}
for name, vname in vmap.items():
    print(f"  {vname}: SHIFT={best_shifts[name]}")
print("=" * 50)

# ── En iyi SHIFT ile .mem dosyalarını üret ─────────────────────────────────────
print("\n--- Bias .mem dosyaları (kalibrasyon sonucu) ---")
quantized_biases = best_biases

for layer_name, q_bias in quantized_biases.items():
    flat = q_bias.flatten()
    with open(f"coe_files/int8/{layer_name}_int8_bias.coe", 'w') as f:
        f.write("memory_initialization_radix=16;\n")
        f.write("memory_initialization_vector=\n")
        f.write(",\n".join(f"{int(v) & 0xFFFFFFFF:08X}" for v in flat))
        f.write(";\n")
    save_as_mem_int32(q_bias, f"coe_files/int8/{layer_name}_int8_bias.mem")

# --- Test Görüntüsü Hazırlama ---
IMAGES_PER_DIGIT = 10
N_TEST_IMAGES = IMAGES_PER_DIGIT * 10
print(f"\n--- Test Görüntüleri (0-9 her rakamdan {IMAGES_PER_DIGIT} örnek, toplam {N_TEST_IMAGES}) ---")

os.makedirs('test_images', exist_ok=True)

# Her rakam için test setinden IMAGES_PER_DIGIT adet rastgele örnek seç (tekrarsız)
import random
random.seed()  # gerçek rastgelelik
candidates = {}
for i, label in enumerate(y_test):
    if label not in candidates:
        candidates[label] = []
    candidates[label].append(i)

sample_list = []  # (global_index, digit, dataset_index) sıralı liste
for digit in range(10):
    chosen = random.sample(candidates[digit], IMAGES_PER_DIGIT)
    for idx in chosen:
        sample_list.append((digit, idx))
random.shuffle(sample_list)  # rakamları karıştır, sıralı gelmesin

ref_lines = []
labels_mem = []

for gi, (digit, idx) in enumerate(sample_list):
    img = x_test[idx]  # shape (28,28,1), float32 0-1

    # Model tahmini
    pred_probs = model.predict(img[np.newaxis, ...], verbose=0)[0]
    predicted_class = int(np.argmax(pred_probs))
    confidence = float(pred_probs[predicted_class])

    print(f"[{gi:03d}] gerçek={digit}, index={idx}, tahmin={predicted_class}, "
          f"güven={confidence:.4f} {'✓' if predicted_class == digit else '✗'}")

    # Piksel değerlerini int8 uyumlu aralığa çevir (0-127)
    # 255 yerine 127: signed [7:0] taşması önlenir (128-255 → negatif olurdu)
    img_uint8 = np.round(img.squeeze() * 127).astype(np.uint8)
    # .mem formatı (Verilog $readmemh için)
    mem_path = f"test_images/img_{gi:03d}_input.mem"
    with open(mem_path, 'w') as f:
        for v in img_uint8.flatten():
            f.write(f"{int(v):02X}\n")

    coe_path = f"test_images/img_{gi:03d}_input.coe"
    with open(coe_path, 'w') as f:
        f.write("memory_initialization_radix=16;\n")
        f.write("memory_initialization_vector=\n")
        hex_vals = [format(int(v), '02X') for v in img_uint8.flatten()]
        f.write(",\n".join(hex_vals))
        f.write(";\n")

    # PNG olarak da kaydet (görsel kontrol için)
    plt.imsave(f"test_images/img_{gi:03d}_label{digit}.png", img.squeeze(), cmap='gray')

    labels_mem.append(f"{digit:X}")

    # Referans satırı: tüm softmax skorları
    scores_str = " ".join(f"{p:.6f}" for p in pred_probs)
    ref_lines.append(
        f"img={gi:03d} digit={digit} index={idx} predicted={predicted_class} "
        f"confidence={confidence:.6f} scores=[{scores_str}]"
    )

# Beklenen etiketleri tek dosyada topla (Verilog $readmemh ile okunur)
with open('test_images/labels.mem', 'w') as f:
    f.write("\n".join(labels_mem))
    f.write("\n")

with open('test_images/reference_outputs.txt', 'w') as f:
    f.write("# MNIST CNN Reference Outputs\n")
    f.write("# Format: img digit index predicted confidence scores[0..9]\n\n")
    f.write("\n".join(ref_lines))
    f.write("\n")

print(f"\nKaydedildi: test_images/ ({N_TEST_IMAGES}x .mem, .coe, .png, labels.mem, reference_outputs.txt)")

# --- Lab 2: Çoklu Quantizasyon Formatları ---
print("\n--- Lab 2: FP32 / INT4 / INT2 Quantizasyon ---")

import struct

def save_as_coe_fp32(array, filename):
    flat = array.flatten().astype(np.float32)
    hex_values = [format(struct.unpack('I', struct.pack('f', v))[0], '08X') for v in flat]
    with open(filename, 'w') as f:
        f.write("memory_initialization_radix=16;\n")
        f.write("memory_initialization_vector=\n")
        f.write(",\n".join(hex_values))
        f.write(";\n")
    print(f"  Kaydedildi: {filename} ({len(flat)} değer, FP32)")

def quantize_int4(weights):
    max_val = np.abs(weights).max()
    scale = 7.0 / max_val
    quantized = np.clip(np.round(weights * scale), -7, 7).astype(np.int8)
    return quantized, scale

def save_as_coe_int4(array, filename):
    flat = array.flatten()
    # İki 4-bit değeri bir byte'a pack et (high nibble | low nibble)
    if len(flat) % 2 != 0:
        flat = np.append(flat, 0)
    packed = []
    for i in range(0, len(flat), 2):
        hi = int(flat[i]) & 0x0F
        lo = int(flat[i+1]) & 0x0F
        packed.append(format((hi << 4) | lo, '02X'))
    with open(filename, 'w') as f:
        f.write("memory_initialization_radix=16;\n")
        f.write("memory_initialization_vector=\n")
        f.write(",\n".join(packed))
        f.write(";\n")
    print(f"  Kaydedildi: {filename} ({len(array.flatten())} değer → {len(packed)} byte, INT4)")

def quantize_int2(weights):
    # Sadece {-1, 0, +1} — işarete göre threshold
    max_val = np.abs(weights).max()
    threshold = max_val / 3.0
    quantized = np.zeros_like(weights, dtype=np.int8)
    quantized[weights >  threshold] =  1
    quantized[weights < -threshold] = -1
    return quantized

def save_as_coe_int2(array, filename):
    flat = array.flatten()
    # Dört 2-bit değeri bir byte'a pack et
    # 2-bit two's complement: 1→01, 0→00, -1→11
    def to_2bit(v):
        if v == 1:  return 0b01
        if v == -1: return 0b11
        return 0b00
    pad = (4 - len(flat) % 4) % 4
    flat = np.append(flat, np.zeros(pad, dtype=np.int8))
    packed = []
    for i in range(0, len(flat), 4):
        byte = (to_2bit(flat[i])   << 6 |
                to_2bit(flat[i+1]) << 4 |
                to_2bit(flat[i+2]) << 2 |
                to_2bit(flat[i+3]))
        packed.append(format(byte, '02X'))
    with open(filename, 'w') as f:
        f.write("memory_initialization_radix=16;\n")
        f.write("memory_initialization_vector=\n")
        f.write(",\n".join(packed))
        f.write(";\n")
    print(f"  Kaydedildi: {filename} ({len(array.flatten())} değer → {len(packed)} byte, INT2)")

formats = {
    'fp32': os.path.join('coe_files', 'fp32'),
    'int4': os.path.join('coe_files', 'int4'),
    'int2': os.path.join('coe_files', 'int2'),
}
for d in formats.values():
    os.makedirs(d, exist_ok=True)

summary_rows = []

for layer in model.layers:
    w = layer.get_weights()
    if not w:
        continue
    weight, bias = w
    name = layer.name
    print(f"\n[{name}] weight shape: {weight.shape}")

    # FP32
    save_as_coe_fp32(weight, f"{formats['fp32']}/{name}_fp32_weights.coe")
    save_as_coe_fp32(bias,   f"{formats['fp32']}/{name}_fp32_bias.coe")

    # INT4
    q4_w, s4_w = quantize_int4(weight)
    q4_b, s4_b = quantize_int4(bias)
    save_as_coe_int4(q4_w, f"{formats['int4']}/{name}_int4_weights.coe")
    save_as_coe_int4(q4_b, f"{formats['int4']}/{name}_int4_bias.coe")

    # INT2
    q2_w = quantize_int2(weight)
    q2_b = quantize_int2(bias)
    save_as_coe_int2(q2_w, f"{formats['int2']}/{name}_int2_weights.coe")
    save_as_coe_int2(q2_b, f"{formats['int2']}/{name}_int2_bias.coe")

    n = weight.size
    summary_rows.append({
        'layer': name,
        'params': n,
        'fp32_bytes': n * 4,
        'int8_bytes': n,
        'int4_bytes': (n + 1) // 2,
        'int2_bytes': (n + 3) // 4,
    })

# Model doğruluk karşılaştırması (her format için ağırlıkları geçici model üzerinde test et)
print("\n--- Format Başına Doğruluk Karşılaştırması ---")

def eval_with_quantized_weights(model, quant_fn, x_test, y_test, n_samples=2000):
    import copy
    test_model = models.clone_model(model)
    test_model.build(input_shape=(None, 28, 28, 1))
    new_weights = []
    for layer in model.layers:
        w = layer.get_weights()
        if not w:
            new_weights.append([])
            continue
        weight, bias = w
        q_w, _ = quant_fn(weight)
        q_b, _ = quant_fn(bias)
        # float'a geri çevir (inference için)
        _, sw = quant_fn(weight)
        _, sb = quant_fn(bias)
        new_weights.append([q_w.astype(np.float32) / sw,
                            q_b.astype(np.float32) / sb])
    for layer, wts in zip(test_model.layers, new_weights):
        if wts:
            layer.set_weights(wts)
    test_model.compile(optimizer='adam',
                       loss='sparse_categorical_crossentropy',
                       metrics=['accuracy'])
    _, acc = test_model.evaluate(x_test[:n_samples], y_test[:n_samples], verbose=0)
    return acc

def int2_as_quantize(weights):
    q = quantize_int2(weights)
    max_val = np.abs(weights).max()
    scale = 1.0 / (max_val / 3.0) if max_val > 0 else 1.0
    return q, scale

acc_fp32 = test_acc  # zaten FP32 modeli
acc_int8 = eval_with_quantized_weights(model, quantize_int8, x_test, y_test)
acc_int4 = eval_with_quantized_weights(model, quantize_int4, x_test, y_test)
acc_int2 = eval_with_quantized_weights(model, int2_as_quantize, x_test, y_test)

print(f"  FP32 : {acc_fp32:.4f}")
print(f"  INT8 : {acc_int8:.4f}")
print(f"  INT4 : {acc_int4:.4f}")
print(f"  INT2 : {acc_int2:.4f}")

# Bellek karşılaştırma tablosu
total = {k: 0 for k in ['params','fp32_bytes','int8_bytes','int4_bytes','int2_bytes']}
for r in summary_rows:
    for k in total:
        total[k] += r[k]

print("\n--- Bellek Kullanımı Özeti ---")
print(f"  Toplam parametre : {total['params']:,}")
print(f"  FP32             : {total['fp32_bytes']:,} byte ({total['fp32_bytes']/1024:.1f} KB)")
print(f"  INT8             : {total['int8_bytes']:,} byte ({total['int8_bytes']/1024:.1f} KB)")
print(f"  INT4             : {total['int4_bytes']:,} byte ({total['int4_bytes']/1024:.1f} KB)")
print(f"  INT2             : {total['int2_bytes']:,} byte ({total['int2_bytes']/1024:.1f} KB)")
print("\nLab 2 dosyaları hazır: coe_files/fp32/, coe_files/int4/, coe_files/int2/")