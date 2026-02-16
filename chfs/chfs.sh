#!/bin/bash

set -e

echo "🚀 开始部署 CHFS..."

# 创建目录
echo "📁 创建目录..."
mkdir -p /mnt/chfs/config
mkdir -p /mnt/chfs/tmp

# 下载配置文件
echo "⬇️ 下载配置文件..."
curl -o /mnt/chfs/config/chfs.ini https://raw.githubusercontent.com/abai569ok/sh/main/chfs/chfs.ini

# 删除旧容器（如果存在）
echo "🧹 清理旧容器..."
docker rm -f chfs 2>/dev/null || true

# 启动容器
echo "🐳 启动 CHFS 容器..."
docker run --name chfs -d -p 88:80 \
  -v /mnt/chfs/tmp:/tmp \
  -v /mnt/chfs/config:/config \
  docblue/chfs:v4.0beta.min

echo ""
echo "✅ CHFS 部署完成！"
echo "🌐 访问地址: http://localhost:88"
echo "📁 共享目录: /mnt/chfs/tmp"
echo "⚙️  配置文件: /mnt/chfs/config/chfs.ini"
echo ""
docker ps | grep chfs
