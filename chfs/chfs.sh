#!/bin/bash

set -e

echo "🚀 开始部署 CHFS..."

# 1. 删除容器和所有数据
echo "🧹 清理旧容器和数据..."
docker rm -f chfs 2>/dev/null || true
rm -rf /mnt/chfs/data
mkdir -p /mnt/chfs/data
chmod 777 /mnt/chfs/data

# 2. 重新下载最新配置
echo "⬇️ 下载配置文件..."
curl -o /mnt/chfs/chfs.ini https://raw.githubusercontent.com/abai569ok/sh/main/chfs/chfs.ini

# 3. 直接修改配置文件
echo "⚙️ 配置文件设置..."
cat > /mnt/chfs/chfs.ini << 'EOF'
port=80
path=/data
html.title=阿白的文件服务器
html.notice=SSH下载专用服务器
image.preview=true
file.remove=3

[guest]
rule.default=r

[admin]
password=admin123
rule.default=d
EOF

# 4. 启动容器
echo "🐳 启动 CHFS 容器..."
docker run --name chfs -d -p 88:80 \
  -v /mnt/chfs/data:/data \
  -v /mnt/chfs/chfs.ini:/config/chfs.ini \
  docblue/chfs:v4.0beta.min

# 5. 查看日志确认
echo ""
echo "📋 容器日志："
docker logs chfs

echo ""
echo "✅ CHFS 部署完成！"
echo "🌐 访问地址: http://localhost:88"
echo "📁 共享目录: /mnt/chfs/data"
echo "⚙️  配置文件: /mnt/chfs/chfs.ini"
echo "👤 管理员用户: admin"
echo "🔑 管理员密码: admin123"
echo ""
docker ps | grep chfs
