#!/bin/bash
# 下载 MLX Whisper 模型到本地
# 支持通过镜像或代理下载

set -e

# 默认模型
MODEL="${1:-mlx-community/whisper-large-v3-turbo}"

echo "═══════════════════════════════════════════════"
echo "📥 下载 MLX Whisper 模型"
echo "═══════════════════════════════════════════════"
echo ""
echo "模型: $MODEL"
echo ""

# 检查 Python
PYTHON=""
for p in /opt/homebrew/bin/python3 /usr/local/bin/python3 /Library/Frameworks/Python.framework/Versions/3.10/bin/python3 /usr/bin/python3; do
    if [ -x "$p" ]; then
        PYTHON="$p"
        break
    fi
done

if [ -z "$PYTHON" ]; then
    echo "❌ 未找到 Python3，请先安装"
    echo "   brew install python3"
    exit 1
fi

echo "Python: $PYTHON"
echo ""

# 确保 huggingface_hub 已安装
echo "🔧 检查依赖..."
$PYTHON -m pip install --quiet huggingface_hub 2>/dev/null || $PYTHON -m pip install huggingface_hub

# 设置镜像（可选，国内用户需要）
# 如果你有代理，可以注释掉下面这行，直接走代理
export HF_ENDPOINT="${HF_ENDPOINT:-https://hf-mirror.com}"
echo "📡 HuggingFace 端点: $HF_ENDPOINT"
echo ""

# 如果设置了代理环境变量，显示出来
if [ -n "$https_proxy" ] || [ -n "$HTTPS_PROXY" ]; then
    echo "🌐 检测到代理: ${https_proxy:-$HTTPS_PROXY}"
    echo ""
fi

echo "⏳ 开始下载（首次约 1.6GB，请耐心等待）..."
echo ""

# 下载模型
$PYTHON -c "
import os
import sys

# 设置镜像
os.environ.setdefault('HF_ENDPOINT', 'https://hf-mirror.com')

from huggingface_hub import snapshot_download

model_id = '$MODEL'
print(f'正在下载: {model_id}')
print(f'端点: {os.environ.get(\"HF_ENDPOINT\", \"https://huggingface.co\")}')
print()

try:
    path = snapshot_download(
        repo_id=model_id,
        repo_type='model',
    )
    print()
    print(f'✅ 下载完成！')
    print(f'📂 模型路径: {path}')
    print()
    print('现在可以在漫画翻译器中使用 MLX Whisper 了。')
    print(f'模型名填: {model_id}')
except KeyboardInterrupt:
    print()
    print('⚠️ 下载已取消')
    sys.exit(1)
except Exception as e:
    print(f'❌ 下载失败: {e}', file=sys.stderr)
    print()
    print('解决方案:')
    print('  1. 如果是网络问题，尝试开代理/VPN 后重试:')
    print('     export https_proxy=http://127.0.0.1:7890')
    print('     ./download_model.sh')
    print()
    print('  2. 或者直接使用 HuggingFace 官方源（需要翻墙）:')
    print('     HF_ENDPOINT=https://huggingface.co ./download_model.sh')
    print()
    print('  3. 使用更小的模型:')
    print('     ./download_model.sh mlx-community/whisper-tiny')
    print('     ./download_model.sh mlx-community/whisper-small-mlx')
    print('     ./download_model.sh mlx-community/whisper-large-v3-turbo-q4')
    sys.exit(1)
"

echo ""
echo "═══════════════════════════════════════════════"
echo ""
echo "可用模型列表（从小到大）:"
echo "  mlx-community/whisper-tiny              (~75MB,  速度最快, 质量一般)"
echo "  mlx-community/whisper-small-mlx         (~481MB, 速度快, 质量好)"
echo "  mlx-community/whisper-large-v3-turbo-q4 (~464MB, 量化版, 接近最佳)"
echo "  mlx-community/whisper-large-v3-turbo    (~1.6GB, 质量最佳, 默认)"
echo ""
echo "下载其他模型: ./download_model.sh <模型名>"
echo ""
