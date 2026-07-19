import sqlite3, json, random, re, os
random.seed(42)
db = os.path.expanduser("~/.koe/history.db")
con = sqlite3.connect(db)
rows = [r[0] for r in con.execute("SELECT text FROM sessions").fetchall()]
con.close()

def clean(t):
    return (t or "").strip()

# Dedupe + keep realistic-length, drop obvious prior degenerate captures
seen=set(); real=[]
for t in rows:
    t=clean(t)
    if not t or t in seen: continue
    n=len(t)
    if n<6 or n>200: continue            # skip ultra-short fragments & huge dumps
    if re.fullmatch(r'[A-Za-z0-9 \-]+', t) and n>40: continue  # skip the dictionary-dump rows
    seen.add(t); real.append(t)
random.shuffle(real)
real = real[:100]

adversarial = [
    # English-dense code-switch (translation trigger)
    "这个 cloud code 还有 PPT master 到底为什么会 collapse 啊？",
    "我们用 Claude Code 配合 Cursor 和 Codex 来写 Rust，然后 deploy 到 Vercel。",
    "ASR 是一个测试的环境，PPT master 是另外一个，我们看一下还会不会崩塌。",
    "let me check whether claude code and PPT master still work fine here.",
    # term stacks (dump trigger)
    "Tailscale Cloudflare Nextcloud Forgejo Miniflux Paperless 这些都是自托管服务。",
    "我在用 DoubaoIME、Sherpa-ONNX、Whisper 还有 MLX 做语音识别的对比。",
    "Anthropic 的 Sonnet Opus Haiku 跟 DeepSeek Qwen 比起来怎么样？",
    # short fragments (collapse trigger)
    "ASR", "PPT master", "LLM", "PTT", "claude code",
    "PPT master PPT master 是一个很好的人。 PPT master",
    # single dict term embedded in a real sentence
    "我觉得 Cloudflare 的隧道功能挺好用的。",
    "帮我把这个文件 push 到 GitHub 上面去。",
    "Obsidian 和 NotebookLM 哪个更适合做知识管理？",
    # mixed punctuation / filler heavy
    "嗯那个就是我想说的其实就是这个 Tauri 的打包有点慢。",
    "呃，这个，那个 Docker 的 compose 文件是不是写错了？",
    # English term sentence (should stay, not translate)
    "Vercel deploy 之后 Rustls 的握手还是有点问题。",
    "Karabiner 和 Hammerspoon 我都配置了快捷键。",
    "这个 OKR 的对齐会议是不是放到下周比较好？",
    "Type4Me 迁移到 koe 之后词典还要不要保留。",
    "cc-connect 这个项目跟 cloudflared 有什么关系吗？",
    "Forgejo 自建 git 跟 GitHub 体验差距大吗？",
]

corpus = real + adversarial
with open("/tmp/koe-corpus.txt","w") as f:
    for t in corpus: f.write(t+"\n")
with open("/tmp/koe-corpus-meta.jsonl","w") as f:
    for i,t in enumerate(corpus):
        src = "real" if i < len(real) else "adversarial"
        f.write(json.dumps({"id":i,"source":src,"asr_text":t}, ensure_ascii=False)+"\n")

print(f"corpus: {len(corpus)} total = {len(real)} real + {len(adversarial)} adversarial")
