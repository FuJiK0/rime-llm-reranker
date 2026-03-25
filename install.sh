#!/usr/bin/env bash
# install.sh - rime-llm-reranker 安装脚本（macOS + Squirrel）

set -e
RIME="$HOME/Library/Rime"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  rime-llm-reranker 安装"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# 检查 Rime
[ ! -d "$RIME" ] && echo "❌ 未找到 ~/Library/Rime，请先安装 Squirrel" && exit 1
echo "✅ Rime 目录：$RIME"

# 复制 rime.lua
cp "$SCRIPT_DIR/rime.lua" "$RIME/rime.lua"
echo "✅ 已安装 rime.lua"

# 复制 custom yaml（若已存在则跳过，避免覆盖用户配置）
YAML="$RIME/luna_pinyin_simp.custom.yaml"
if [ -f "$YAML" ]; then
  echo "⚠️  $YAML 已存在，跳过（请手动合并 config/ 目录下的配置）"
else
  cp "$SCRIPT_DIR/config/luna_pinyin_simp.custom.yaml" "$YAML"
  echo "✅ 已安装 luna_pinyin_simp.custom.yaml"
fi

# 检查 oMLX
echo ""
if curl -s --max-time 1 http://localhost:8000/v1/models > /dev/null 2>&1; then
  echo "✅ oMLX 运行中"
  echo "   可用模型："
  curl -s http://localhost:8000/v1/models | python3 -c \
    "import sys,json; [print('   -',m['id']) for m in json.load(sys.stdin)['data']]" 2>/dev/null
else
  echo "⚠️  oMLX 未运行，请启动后再使用"
fi

# 检查 luasocket
echo ""
if lua5.4 -e "require('socket.http')" 2>/dev/null || \
   [ -f "$HOME/.luarocks/lib/lua/5.4/socket/core.so" ]; then
  echo "✅ luasocket 已安装（低延迟模式）"
else
  echo "⚠️  luasocket 未安装（使用 curl 模式，延迟略高）"
  echo "   安装命令："
  echo "     brew install luarocks"
  echo "     luarocks --lua-dir=/opt/homebrew/opt/lua@5.4 install luasocket"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  安装完成！"
echo "  请点击菜单栏 Squirrel 图标 → 重新部署"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
