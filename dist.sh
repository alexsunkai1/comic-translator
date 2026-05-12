#!/bin/bash
# 打包分发脚本：构建 .app，生成 .dmg 和 .zip

set -e

cd "$(dirname "$0")"

APP_NAME="ComicTranslator"
DISPLAY_NAME="漫画翻译器"
VERSION="1.2.0"
APP_BUNDLE="$APP_NAME.app"
DIST_DIR="dist"

echo "═══════════════════════════════════════════════"
echo "📦 构建分发包 $APP_NAME v$VERSION"
echo "═══════════════════════════════════════════════"

# 1. 构建 .app
if [ ! -d "$APP_BUNDLE" ]; then
    echo ""
    echo "🔨 构建 .app..."
    ./build_app.sh
else
    read -p "已存在 $APP_BUNDLE，是否重新构建？(y/N) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        ./build_app.sh
    fi
fi

# 2. 清理并创建分发目录
rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"

# 3. 生成 ZIP 包
echo ""
echo "📁 生成 ZIP 包..."
ZIP_NAME="${APP_NAME}-v${VERSION}-macOS.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$DIST_DIR/$ZIP_NAME"
ZIP_SIZE=$(du -h "$DIST_DIR/$ZIP_NAME" | cut -f1)
echo "   ✅ $DIST_DIR/$ZIP_NAME ($ZIP_SIZE)"

# 4. 生成 DMG 镜像
echo ""
echo "💿 生成 DMG 镜像..."
DMG_NAME="${APP_NAME}-v${VERSION}.dmg"
DMG_STAGE="$DIST_DIR/dmg_stage"

rm -rf "$DMG_STAGE"
mkdir -p "$DMG_STAGE"
cp -R "$APP_BUNDLE" "$DMG_STAGE/"
ln -s /Applications "$DMG_STAGE/Applications"

hdiutil create \
    -volname "$DISPLAY_NAME" \
    -srcfolder "$DMG_STAGE" \
    -ov \
    -format UDZO \
    -imagekey zlib-level=9 \
    "$DIST_DIR/$DMG_NAME" > /dev/null

rm -rf "$DMG_STAGE"

DMG_SIZE=$(du -h "$DIST_DIR/$DMG_NAME" | cut -f1)
echo "   ✅ $DIST_DIR/$DMG_NAME ($DMG_SIZE)"

# 5. 生成 SHA256 校验和
echo ""
echo "🔏 生成校验和..."
(cd "$DIST_DIR" && shasum -a 256 *.zip *.dmg > SHA256SUMS.txt)
echo "   ✅ $DIST_DIR/SHA256SUMS.txt"

# 6. 生成使用说明
cat > "$DIST_DIR/README.txt" <<EOF
$DISPLAY_NAME v$VERSION
================================================

v1.2.0 更新
- ✨ 界面美化：全新视觉设计，更清晰的布局层次
- ✨ 日志增强：每步操作显示耗时统计（OCR/翻译/渲染/打包）
- ✨ 日志时间戳：精确到秒的时间显示
- ✨ 代码优化：更好的错误处理和性能

v1.1.0 更新
- ✨ 支持批量翻译：一次添加多个压缩包
- ✨ 文件列表视图：每个文件独立进度和状态
- ✨ 支持拖拽多个文件
- ✨ 失败不中断：单个文件出错继续处理下一个

安装方式（任选其一）：

【方式 A - DMG 镜像（推荐）】
1. 双击 $DMG_NAME 打开镜像
2. 把 $APP_NAME.app 拖到 Applications 文件夹
3. 从启动台打开应用

【方式 B - ZIP 压缩包】
1. 双击 $ZIP_NAME 解压
2. 把 $APP_NAME.app 拖到 /Applications 或任意位置
3. 双击打开

================================================
⚠️ 首次打开可能被 macOS Gatekeeper 拦截
================================================

如果出现"无法打开，因为无法验证开发者"的提示：

方法 1：右键打开（最简单）
  在 Finder 中右键（或 Control+点击）应用图标 → 打开 → 再点"打开"

方法 2：系统设置中允许
  系统设置 → 隐私与安全性 → 底部"仍要打开"

方法 3：终端命令放行
  xattr -dr com.apple.quarantine /Applications/$APP_NAME.app

================================================
系统要求
================================================
- macOS 14.0 或更高版本
- Apple Silicon 或 Intel（Universal Binary）

================================================
功能特性
================================================
- 批量翻译 ZIP / CBZ / RAR / CBR / 7z / tar.gz 等
- OCR + 自动翻译 + 原位渲染
- 支持本地模型（Ollama / HY-MT）和在线 API（OpenAI 兼容）
- 13 种领域优化：漫画、财经、科技、医学、法律等
- 多文件并发处理
- 每步耗时统计，方便性能调优

================================================
翻译 API 配置
================================================
应用启动后在界面内配置：

【本地 Ollama 模型】
  API 类型: Ollama / HY-MT
  Endpoint: http://localhost:11434
  模型: 点击刷新按钮选择已安装的模型

【OpenAI 兼容接口】
  API 类型: OpenAI 兼容
  Endpoint: 你的 API 地址
  API Key: 你的 key
  模型: gpt-4o-mini 等

================================================
外部工具（仅 RAR/CBR/7z 需要）
================================================
brew install unrar    # RAR 和 CBR
brew install p7zip    # 7z

EOF
echo "   ✅ $DIST_DIR/README.txt"

# 7. 汇总
echo ""
echo "═══════════════════════════════════════════════"
echo "✅ 分发包生成完成！"
echo "═══════════════════════════════════════════════"
echo ""
echo "📂 位置: $(pwd)/$DIST_DIR"
echo ""
ls -lh "$DIST_DIR" | tail -n +2 | awk '{printf "   %-40s %s\n", $NF, $5}'
echo ""
echo "分发建议："
echo "  • 发 .dmg 给普通用户（最友好）"
echo "  • 发 .zip 给技术用户（更小更快）"
echo "  • README.txt 含安装说明和 Gatekeeper 放行方法"
echo ""
