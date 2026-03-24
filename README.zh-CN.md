# Koe (声)

[English](./README.md) | [简体中文](./README.zh-CN.md)

一个零 GUI 的 macOS 语音输入工具。按下热键，说话，修正后的文本会自动粘贴到你当前使用的应用中。

更多信息请访问文档站点：**[koe.li](https://koe.li)**。

## 名称由来

**Koe**（声，发音近似 “ko-eh”）是日语里“声音”的意思。写作平假名 こえ，是日语里最基础、最直接的词之一。这也正是这个工具的理念：声音输入，干净文本输出，中间没有多余步骤。没有花哨 UI，没有不必要交互。只有“声”本身。

## 为什么是 Koe？

我几乎试过市面上所有语音输入应用。它们往往要么收费、要么难看、要么不好用：UI 臃肿、词典管理繁琐、做一件简单的事却要点很多次。

Koe 走的是另一条路：

- **完全无 GUI**。唯一可见元素是菜单栏里的一个小图标。
- **所有配置都在纯文本文件里**，位于 `~/.koe/`。你可以用任意编辑器、vim，甚至脚本来改。
- **词典就是一个普通 `.txt` 文件**。不需要打开 App 在 GUI 里一个个添加词条。直接编辑 `~/.koe/dictionary.txt`，一行一个词。你甚至可以用 Claude Code 或其他 AI 工具批量生成领域词汇。
- **改完立即生效**。修改任意配置文件后会自动使用新设置。ASR、LLM、词典、提示词都会在下一次热键触发时生效。热键改动会在几秒内被检测到。无需重启，无需点击“重新加载”。
- **体积很小**。安装后 Koe 依然 **小于 15 MB**，内存占用通常 **约 20 MB**。启动快、占盘少、不打扰。
- **基于 macOS 原生技术**。Objective-C 直接通过 Apple API 处理热键、音频采集、剪贴板、权限和粘贴自动化。
- **Rust 负责核心计算与网络**。性能关键路径在 Rust 中实现，低开销、执行快、内存安全性更强。
- **没有 Chromium 体积税**。很多 Electron 同类应用体积 **200+ MB**，且带着嵌入式 Chromium 的运行时开销。Koe 不依赖这套栈，因此更轻量。

## 工作原理

1. 按住触发键（默认 **Fn**，可配置）— Koe 开始监听
2. 音频实时流式发送到云 ASR 服务（字节跳动豆包）
3. ASR 文本再交给 LLM（任意 OpenAI-compatible API）修正大小写、标点、空格和术语
4. 修正后的文本自动粘贴到当前焦点输入框

当前 Provider 支持刻意保持精简：

- **ASR**：目前仅支持 **Doubao ASR**
- **LLM**：目前仅支持 **OpenAI-compatible API**
- **计划中**：未来 ASR 可能支持 **OpenAI Transcriptions API**

## 安装

Koe 当前仅支持 **Apple Silicon Mac**。预构建二进制和当前构建配置都面向 `aarch64-apple-darwin`，因此不支持 `x86_64` Intel Mac。

### Homebrew

```bash
brew tap owo-network/brew
brew install owo-network/brew/koe
```

### Release

你也可以直接从 GitHub 下载最新发布版本：

- [下载最新 release](https://github.com/missuo/koe/releases/latest)

### 从源码构建

#### 前置条件

- macOS 13.0+
- Apple Silicon Mac（`aarch64-apple-darwin`）
- Rust 工具链（`rustup`）
- Xcode 与命令行工具
- [xcodegen](https://github.com/yonaskolb/XcodeGen)（`brew install xcodegen`）

#### 构建

```bash
git clone https://github.com/missuo/koe.git
cd koe

# 生成 Xcode 工程
cd KoeApp && xcodegen && cd ..

# 构建全部
make build
```

#### 运行

```bash
make run
```

或直接打开编译出的 App：

```bash
open ~/Library/Developer/Xcode/DerivedData/Koe-*/Build/Products/Release/Koe.app
```

### 权限

Koe 运行需要 **3 项 macOS 权限**。首次启动会提示授权。三项都很重要，缺任意一项都无法完整走通核心流程。

| 权限 | 需要它的原因 | 缺失时会怎样 |
|---|---|---|
| **麦克风** | 采集麦克风音频并流式发送到 ASR 服务进行识别 | Koe 完全听不到声音，无法开始录音 |
| **辅助功能（Accessibility）** | 模拟 `Cmd+V` 把修正文本粘贴到任意应用当前输入框 | Koe 仍会写入剪贴板，但无法自动粘贴，需要手动粘贴 |
| **输入监控（Input Monitoring）** | 全局监听触发键（默认 **Fn**，可配置），无论前台是哪个应用都能识别按下/松开 | Koe 无法检测热键，也就无法触发录音 |

授权路径：**系统设置 → 隐私与安全性**，在上述 3 个分类中启用 Koe。

## 配置

所有配置文件都在 `~/.koe/`，首次启动会自动生成：

```
~/.koe/
├── config.yaml          # 主配置
├── dictionary.txt       # 用户词典（热词 + LLM 修正参考）
├── history.db           # 使用统计（SQLite，自动创建）
├── system_prompt.txt    # LLM 系统提示词（可自定义）
└── user_prompt.txt      # LLM 用户提示词模板（可自定义）
```

### config.yaml

下面是完整配置及字段说明。

#### ASR（语音识别）

Koe 当前流式识别仅支持 **Doubao（豆包）ASR 2.0**。
目前尚不支持其他 ASR Provider。未来可能增加 **OpenAI Transcriptions API** 支持。

```yaml
asr:
  # WebSocket endpoint。默认使用 ASR 2.0 优化双向流式。
  # 除非明确知道影响，否则不要修改。
  url: "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async"

  # 火山引擎凭据，可在火山引擎控制台获取。
  # 入口: https://console.volcengine.com/speech/app → 创建应用 → 复制 App ID 和 Access Token。
  app_key: ""          # X-Api-App-Key (火山引擎 App ID)
  access_key: ""       # X-Api-Access-Key (火山引擎 Access Token)

  # 计费资源 ID。默认是按时长计费方案。
  resource_id: "volc.seedasr.sauc.duration"

  # 连接超时时间（毫秒）。网络慢时可适当调大。
  connect_timeout_ms: 3000

  # 停止说话后等待 ASR 最终结果的时长（毫秒）。
  # 在该时间内未收到 final，会使用当前最优结果。
  final_wait_timeout_ms: 5000

  # 语义顺滑（去口语重复/语气词），如 嗯、那个。
  # 建议 true；如果你想要原始转写可设为 false。
  enable_ddc: true

  # 文本规范化（ITN），将口语数字/日期转为规范文本。
  # 例如: "二零二四年" → "2024年", "百分之五十" → "50%"
  # 建议 true。
  enable_itn: true

  # 自动标点。自动补逗号、句号、问号等。
  # 建议 true。
  enable_punc: true

  # 二遍识别。首遍快速流式，二遍更高精度复识别。
  # 延迟会略增（约 200ms），但准确率明显提升，尤其是技术术语。
  # 建议 true。
  enable_nonstream: true
```

#### LLM（文本修正）

ASR 后，文本会发送给 LLM 做修正（大小写、空格、术语、语气词等）。
当前该步骤仅支持 **OpenAI-compatible API**。不兼容 OpenAI 协议的原生 API 不能直接使用。

```yaml
llm:
  # OpenAI-compatible API endpoint。
  # 示例:
  #   OpenAI:    "https://api.openai.com/v1"
  #   Anthropic: "https://api.anthropic.com/v1"  (需兼容代理)
  #   Local:     "http://localhost:8080/v1"
  base_url: ""

  # API key。支持 ${VAR_NAME} 环境变量替换。
  # 示例:
  #   直接写:  "sk-xxxxxxxx"
  #   环境变量: "${LLM_API_KEY}"
  api_key: ""

  # 模型名。建议选择快、便宜模型，因为这里对延迟敏感。
  # 推荐: "gpt-4o-mini" 或同级别快模型。
  model: ""

  # 采样参数。temperature=0 更稳定，适合修正任务。
  temperature: 0
  top_p: 1

  # LLM 请求超时（毫秒）。
  timeout_ms: 8000

  # LLM 最大输出 token。语音修正任务 1024 通常足够。
  max_output_tokens: 1024

  # 送入 LLM 提示词的词典条目数量。
  # 0 = 全部发送（词典 <500 条时推荐）。
  # 词典很大时可设置上限以减少提示词体积。
  dictionary_max_candidates: 0

  # 提示词文件路径（相对 ~/.koe/）。
  # 你可以编辑这些文件来自定义修正行为。
  system_prompt_path: "system_prompt.txt"
  user_prompt_path: "user_prompt.txt"
```

#### 反馈音效（Sound Effects）

```yaml
feedback:
  start_sound: true    # 开始录音时播放提示音
  stop_sound: true     # 停止录音时播放提示音
  error_sound: true    # 出错时播放提示音
```

#### 热键

```yaml
hotkey:
  # 语音输入触发键
  # 可选: fn | left_option | right_option | left_command | right_command
  trigger_key: "fn"
```

| 选项 | 按键 | 说明 |
|---|---|---|
| `fn` | Fn/Globe | 默认值，适配大多数 Mac 键盘 |
| `left_option` | 左 Option | 当 Fn 被重映射时是不错替代 |
| `right_option` | 右 Option | 与常见快捷键冲突最少 |
| `left_command` | 左 Command | 可能和系统快捷键冲突 |
| `right_command` | 右 Command | 相比左 Command 冲突更少 |

热键改动几秒内自动生效，无需重启。

#### 词典

```yaml
dictionary:
  path: "dictionary.txt"  # 相对 ~/.koe/
```

### 词典

词典有两个作用：

1. **ASR 热词**：发送给识别引擎，提高特定术语识别准确率
2. **LLM 修正参考**：放入提示词，让 LLM 优先采用这些拼写和术语

编辑 `~/.koe/dictionary.txt`：

```
# 一行一个词。以 # 开头的是注释。
Cloudflare
PostgreSQL
Kubernetes
GitHub Actions
VS Code
```

#### 批量生成词典条目

你不需要一个个手敲词条，可以借助 AI 工具批量生成领域词汇。例如使用 [Claude Code](https://claude.com/claude-code)：

```
你：把常见 DevOps 和云基础设施术语加到我的 ~/.koe/dictionary.txt 里
```

也可以用简单 shell 命令：

```bash
# 从项目代码中追加术语
grep -roh '[A-Z][a-zA-Z]*' src/ | sort -u >> ~/.koe/dictionary.txt

# 从 package.json 依赖中追加术语
jq -r '.dependencies | keys[]' package.json >> ~/.koe/dictionary.txt
```

因为词典本质就是文本文件，你可以版本管理、跨机器同步，或用脚本自动维护。

### 提示词（Prompts）

LLM 修正行为通过两个提示词文件完全可定制：

- **`~/.koe/system_prompt.txt`**：定义修正规则（大小写、空格、标点、语气词等）
- **`~/.koe/user_prompt.txt`**：把 ASR 输出、中间修订历史和词典组装成最终 LLM 请求

`user_prompt.txt` 可用占位符：

| 占位符 | 说明 |
|---|---|
| `{{asr_text}}` | 最终 ASR 转写文本 |
| `{{interim_history}}` | ASR 中间修订历史（能看到文本如何变化，帮助识别不确定词） |
| `{{dictionary_entries}}` | 送入 LLM 的过滤后词典条目 |

默认提示词偏向中英混合的软件开发语境；你也可以改成任何语言或领域。

## 使用统计

Koe 会把语音输入使用数据记录到本地 SQLite：`~/.koe/history.db`。你可以在菜单栏下拉中直接看汇总，包括总字符/词数、录音时长、会话次数和输入速度。

### 数据库结构

```sql
CREATE TABLE sessions (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    timestamp INTEGER NOT NULL,   -- Unix timestamp
    duration_ms INTEGER NOT NULL, -- 录音时长（毫秒）
    text TEXT NOT NULL,            -- 最终转写文本
    char_count INTEGER NOT NULL,  -- 中文字符数
    word_count INTEGER NOT NULL   -- 英文单词数
);
```

### 查询你的数据

你可以直接用 `sqlite3` 查询：

```bash
# 查看最近会话
sqlite3 ~/.koe/history.db "SELECT * FROM sessions ORDER BY timestamp DESC LIMIT 10;"

# 总体统计
sqlite3 ~/.koe/history.db "SELECT COUNT(*) as sessions, SUM(duration_ms)/1000 as total_seconds, SUM(char_count) as chars, SUM(word_count) as words FROM sessions;"

# 按天统计
sqlite3 ~/.koe/history.db "SELECT date(timestamp, 'unixepoch', 'localtime') as day, COUNT(*) as sessions, SUM(char_count) as chars, SUM(word_count) as words FROM sessions GROUP BY day ORDER BY day DESC;"
```

你也可以基于这个标准 SQLite 文件做自己的可视化或看板。

## AI 辅助配置

Koe 提供了一个可用于 AI 编码助手（Claude Code、Codex 等）的 skill，可以交互式引导你完成配置。

### 安装 Skill

```bash
npx skills add missuo/koe
```

该命令会让你选择安装到哪种 AI 编码工具中。

### 它会做什么

安装后，`koe-setup` skill 会：

1. 检查安装和权限状态
2. 引导你配置 ASR 和 LLM 凭据
3. 询问你的职业并生成**个性化词典**
4. 按你的场景定制 **system prompt**
5. 帮你配置触发键和提示音

对于首次使用、希望低成本完成配置的用户，这个流程很实用。

## 架构

Koe 是一个双层原生 macOS 应用：

- **Objective-C 外壳层**：负责 macOS 集成（热键检测、音频采集、剪贴板管理、模拟粘贴、菜单栏 UI、SQLite 统计）
- **Rust 核心库**：负责所有网络相关流程（ASR 2.0 WebSocket 流式识别、LLM API 调用、配置管理、转写聚合、会话编排）

两层通过 C FFI（Foreign Function Interface）通信。Rust 核心会编译成静态库 `libkoe_core.a` 并链接进 Xcode 工程。

```
┌──────────────────────────────────────────────────┐
│  macOS (Objective-C)                             │
│  ┌──────────┐ ┌──────────┐ ┌───────────────────┐│
│  │ Hotkey   │ │ Audio    │ │ Clipboard + Paste ││
│  │ Monitor  │ │ Capture  │ │                   ││
│  └────┬─────┘ └────┬─────┘ └────────▲──────────┘│
│       │             │                │           │
│  ┌────▼─────────────▼────────────────┴─────────┐ │
│  │           SPRustBridge (FFI)                 │ │
│  └────────────────┬────────────────────────────┘ │
│                   │                              │
│  ┌────────────────┴───────┐  ┌────────────────┐  │
│  │ Menu Bar + Status Bar  │  │ History Store  │  │
│  │ (SPStatusBarManager)   │  │ (SQLite)       │  │
│  └────────────────────────┘  └────────────────┘  │
└───────────────────┼──────────────────────────────┘
                    │ C ABI
┌───────────────────▼──────────────────────────────┐
│  Rust Core (libkoe_core.a)                       │
│  ┌──────────────┐ ┌────────┐ ┌────────────────┐  │
│  │ ASR 2.0      │ │ LLM    │ │ Config + Dict  │  │
│  │ (WebSocket)  │ │ (HTTP) │ │ + Prompts      │  │
│  │ Two-pass     │ │        │ │                │  │
│  └──────┬───────┘ └───▲────┘ └────────────────┘  │
│         │             │                          │
│  ┌──────▼─────────────┴──────────────────────┐   │
│  │ TranscriptAggregator                      │   │
│  │ (interim → definite → final + history)    │   │
│  └───────────────────────────────────────────┘   │
└──────────────────────────────────────────────────┘
```

### ASR 流程

1. 音频通过 WebSocket（二进制协议 + gzip 压缩）发送到 Doubao ASR 2.0
2. 首遍流式结果实时返回（`Interim`）
3. 二遍复识别给出更高精度确认段（`Definite`）
4. `TranscriptAggregator` 聚合结果并记录 interim 修订历史
5. 最终文本 + interim 历史 + 词典一起送入 LLM 做修正

## License

MIT
