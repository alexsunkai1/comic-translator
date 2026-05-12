# Comic Translator 漫画翻译器

一款独立的 macOS GUI 应用，用于批量翻译 PDF 和压缩包（ZIP/CBZ/RAR/CBR/7z 等）中的图片。

OCR 基于 Apple Vision，翻译调用可配置的 API（Ollama 本地模型、OpenAI 兼容、HY-MT 等）。

## 功能特点

- 🖼️ **多格式支持**：PDF、ZIP、CBZ、RAR、CBR、7z、tar.gz、tar.bz2、tar.xz
- 🌐 **多 API 支持**：Ollama、HY-MT 混元翻译、OpenAI 兼容接口
- 🗣️ **多语言**：17+ 种语言互译，支持自动检测
- 🎨 **原位替换**：保留原图背景，在原文位置渲染译文
- ⚡ **并发翻译**：可配置 1~16 路并发加速
- 🔄 **翻译缓存**：重复文本不重复调用
- 💾 **持久化设置**：API 配置、语言偏好自动保存
- 🖱️ **拖放支持**：直接拖拽 PDF 或压缩包到应用
- 📊 **实时日志**：详细的处理进度和状态

## 系统要求

- macOS 14.0+
- Apple Silicon 或 Intel（通用二进制）

## 构建和运行

### 构建打包

```bash
cd ComicTranslator
./build_app.sh
```

构建完成后，`ComicTranslator.app` 会生成在当前目录。

### 直接运行

```bash
open ComicTranslator.app
```

或拖到 `/Applications/` 目录永久安装：

```bash
mv ComicTranslator.app /Applications/
```

### 开发模式运行

```bash
swift run
```

## 使用方法

### 1. 配置翻译 API

在 "翻译 API" 区域设置：

- **API 类型**：选择 Ollama / OpenAI 兼容 / HY-MT
- **Endpoint**：API 地址
  - Ollama: `http://localhost:11434`
  - OpenAI: `https://api.openai.com/v1`
  - 自定义本地模型: `http://localhost:8080/v1`
- **API Key**：仅 OpenAI 兼容接口需要
- **模型**：点击刷新按钮自动列出可用模型

点击"测试连接"验证 API 可用。

### 2. 配置语言

在 "语言设置" 区域选择：

- **源语言**：原文语言（支持自动检测）
- **目标语言**：翻译目标
- **输出格式**：与输入相同 / ZIP / CBZ

### 3. 选择文件

点击"选择..."或拖拽 PDF、压缩包、音频或视频到文件区域。

### 4. 开始翻译

点击"开始翻译"（⌘ + Return），右侧会显示实时进度和日志。

### 5. 查看结果

翻译完成后，点击"在 Finder 中显示"打开输出文件位置。

## 高级设置

### 并发数

默认 4 路并行翻译。本地小模型建议 2~8，在线 API 根据限流配置。

### 温度参数

默认 0.7。翻译任务建议 0.3~0.7 之间，过高会产生不稳定输出。

### 自定义 Prompt 模板

支持变量：
- `{text}` - 待翻译文本
- `{source}` / `{target}` - 源/目标语言名称（中文）
- `{source_code}` / `{target_code}` - 语言代码

例如：
```
请将以下{source}文本翻译为{target}，保持原意但使用自然的表达：

{text}
```

## 常见 API 配置示例

### Ollama + HY-MT

```
API 类型: HY-MT
Endpoint: http://localhost:11434
模型: demonbyron/HY-MT1.5-1.8B:latest
```

### Ollama + 通用模型

```
API 类型: Ollama
Endpoint: http://localhost:11434
模型: qwen2.5:7b
```

### OpenAI

```
API 类型: OpenAI 兼容
Endpoint: https://api.openai.com/v1
API Key: sk-...
模型: gpt-4o-mini
```

### LM Studio / llama.cpp

```
API 类型: OpenAI 兼容
Endpoint: http://localhost:1234/v1
模型: (选择已加载的模型)
```

### DeepSeek

```
API 类型: OpenAI 兼容
Endpoint: https://api.deepseek.com/v1
API Key: sk-...
模型: deepseek-chat
```

## 外部工具依赖

处理 RAR/CBR 和 7z 格式需要额外安装：

```bash
# RAR/CBR
brew install unrar

# 7z
brew install p7zip
```

其他格式（ZIP/CBZ/tar/tar.gz 等）使用系统自带工具，无需额外安装。

## 处理流程

```
输入文件（.pdf / .cbz / .zip / .rar ...）
    ↓
PDF 渲染为逐页图片 / 压缩包解压到临时目录
    ↓
逐张图片 → Apple Vision OCR → 翻译 API → 渲染（背景色覆盖 + 译文绘制）
    ↓
重新生成 PDF / 重新打包
    ↓
输出文件（-中文.pdf / -中文.cbz）
```

## 项目结构

```
ComicTranslator/
├── Package.swift                # SPM 包定义
├── build_app.sh                 # 打包脚本
├── Sources/ComicTranslator/
│   ├── App.swift                # SwiftUI App 入口
│   ├── ContentView.swift        # 主界面
│   ├── Settings.swift           # 设置模型
│   ├── TranslationAPI.swift     # 翻译 API 协议和实现
│   ├── OCREngine.swift          # OCR 封装
│   ├── ImageRenderer.swift      # 图片渲染
│   ├── ArchiveHandler.swift     # 压缩包处理
│   └── Translator.swift         # 主协调器
```

## 许可证

GPL-3.0（继承自 TranScreen 项目）
