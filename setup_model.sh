#!/bin/bash
# 手动放置 MLX Whisper 模型文件
# 从 HuggingFace 网页手动下载文件后，运行此脚本设置正确的目录结构

set -e

MODEL_ID="mlx-community/whisper-large-v3-turbo"
CACHE_DIR="$HOME/.cache/huggingface/hub"
MODEL_DIR="$CACHE_DIR/models--mlx-community--whisper-large-v3-turbo"
SNAPSHOT_DIR="$MODEL_DIR/snapshots/main"
BLOBS_DIR="$MODEL_DIR/blobs"
REFS_DIR="$MODEL_DIR/refs"

echo "═══════════════════════════════════════════════"
echo "📂 设置 MLX Whisper 模型目录"
echo "═══════════════════════════════════════════════"
echo ""
echo "模型: $MODEL_ID"
echo "目标: $SNAPSHOT_DIR"
echo ""

# 创建目录
mkdir -p "$SNAPSHOT_DIR"
mkdir -p "$BLOBS_DIR"
mkdir -p "$REFS_DIR"

# 写入 refs
echo "main" > "$REFS_DIR/main"

echo "✅ 目录已创建"
echo ""
echo "请从以下链接下载文件，放入目录:"
echo ""
echo "📁 目标目录: $SNAPSHOT_DIR"
echo ""
echo "需要下载的文件（在浏览器中逐个下载）:"
echo ""
echo "  1. config.json"
echo "     https://huggingface.co/mlx-community/whisper-large-v3-turbo/resolve/main/config.json"
echo ""
echo "  2. weights.safetensors (约 1.6GB)"
echo "     https://huggingface.co/mlx-community/whisper-large-v3-turbo/resolve/main/weights.safetensors"
echo ""
echo "═══════════════════════════════════════════════"
echo ""

# 检查文件是否已存在
READY=true
for f in config.json weights.safetensors; do
    if [ -f "$SNAPSHOT_DIR/$f" ]; then
        SIZE=$(du -h "$SNAPSHOT_DIR/$f" | cut -f1)
        echo "  ✅ $f ($SIZE)"
    else
        echo "  ❌ $f (未找到)"
        READY=false
    fi
done

echo ""

if [ "$READY" = true ]; then
    echo "═══════════════════════════════════════════════"
    echo "✅ 所有文件就绪！可以使用 MLX Whisper 了"
    echo "═══════════════════════════════════════════════"
else
    echo "═══════════════════════════════════════════════"
    echo "⚠️ 请下载缺失的文件到: $SNAPSHOT_DIR"
    echo "═══════════════════════════════════════════════"
    echo ""
    echo "下载完成后重新运行此脚本验证:"
    echo "  ./setup_model.sh"
    echo ""
    echo "提示: 如果浏览器下载慢，可以用 aria2 加速:"
    echo "  brew install aria2"
    echo "  aria2c -x 16 -s 16 'https://huggingface.co/mlx-community/whisper-large-v3-turbo/resolve/main/weights.safetensors' -d '$SNAPSHOT_DIR'"
    echo "  aria2c 'https://huggingface.co/mlx-community/whisper-large-v3-turbo/resolve/main/config.json' -d '$SNAPSHOT_DIR'"
fi
echo ""
