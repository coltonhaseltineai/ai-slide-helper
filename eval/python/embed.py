#!/usr/bin/env python3
"""Embed texts with a tiny sentence-embedding model (developer benchmark only).

Usage: embed.py <model> <in.json> <out.f32>
  model: bge-small | minilm | potion
  in.json: a JSON list of strings. out.f32: raw little-endian float32, N x D, L2-normalised.
Prints the dimension on stdout. Needs: onnxruntime, tokenizers, numpy.
"""
import json, os, struct, sys
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
EVAL = os.path.dirname(HERE)
MODELS = {
    'bge-small': dict(dir='models/bge-small-en-v1.5', onnx='model_optimized.onnx', pool='cls'),
    'minilm': dict(dir='models/all-MiniLM-L6-v2', onnx='model.onnx', pool='mean'),
}

def l2(x):
    n = np.linalg.norm(x, axis=1, keepdims=True)
    return x / np.maximum(n, 1e-12)

def embed_onnx(name, texts):
    import onnxruntime as ort
    from tokenizers import Tokenizer
    cfg = MODELS[name]
    d = os.path.join(EVAL, cfg['dir'])
    tok = Tokenizer.from_file(os.path.join(d, 'tokenizer.json'))
    tok.enable_truncation(max_length=128)
    tok.enable_padding(pad_id=0, pad_token='[PAD]')
    sess = ort.InferenceSession(os.path.join(d, cfg['onnx']), providers=['CPUExecutionProvider'])
    out = []
    for i in range(0, len(texts), 64):
        enc = tok.encode_batch(texts[i:i + 64])
        ids = np.array([e.ids for e in enc], dtype=np.int64)
        mask = np.array([e.attention_mask for e in enc], dtype=np.int64)
        feeds = {'input_ids': ids, 'attention_mask': mask, 'token_type_ids': np.zeros_like(ids)}
        h = sess.run(None, feeds)[0]
        if cfg['pool'] == 'cls':
            v = h[:, 0, :]
        else:
            m = mask[:, :, None].astype(np.float32)
            v = (h * m).sum(1) / np.maximum(m.sum(1), 1e-9)
        out.append(l2(v.astype(np.float32)))
    return np.concatenate(out) if out else np.zeros((0, 384), np.float32)

def embed_potion(texts):
    from tokenizers import BertWordPieceTokenizer
    d = os.path.join(EVAL, 'node_modules', 'counterparts-model-potion')
    with open(os.path.join(d, 'model.safetensors'), 'rb') as f:
        n = struct.unpack('<Q', f.read(8))[0]
        header = json.loads(f.read(n))
        start, end = header['embeddings']['data_offsets']
        f.seek(8 + n + start)
        table = np.frombuffer(f.read(end - start), dtype=np.float32).reshape(header['embeddings']['shape'])
    tok = BertWordPieceTokenizer(os.path.join(d, 'vocab.txt'), lowercase=True, strip_accents=True, clean_text=True)
    unk = tok.token_to_id('[UNK]')
    rows = []
    for t in texts:
        ids = [i for i in tok.encode(t, add_special_tokens=False).ids if i != unk]
        rows.append(table[ids].mean(0) if ids else np.zeros(table.shape[1], np.float32))
    return l2(np.array(rows, dtype=np.float32))

def main():
    name, src, dst = sys.argv[1:4]
    texts = json.load(open(src))
    vecs = embed_potion(texts) if name == 'potion' else embed_onnx(name, texts)
    vecs.astype('<f4').tofile(dst)
    print(vecs.shape[1])

if __name__ == '__main__':
    main()
