#!/bin/bash

# 检查是否以root用户运行
if [ "$EUID" -ne 0 ]; then
  echo "错误：此脚本必须以root用户运行。"
  exit 1
fi

# 生成随机密码的函数
generate_password() {
  openssl rand -base64 24 | tr -d '/+=' | head -c 32
}

# 提示输入域名和端口
read -p "请输入您的域名： " DOMAIN
if [ -z "$DOMAIN" ]; then
  echo "错误：域名不能为空。"
  exit 1
fi

read -p "请输入监听端口： " PORT
if ! [[ "$PORT" =~ ^[0-9]+$ ]] || [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
  echo "错误：无效的端口号，请输入1到65535之间的数字。"
  exit 1
fi

# 生成随机密码
PASSWORD=$(generate_password)
EMAIL="lfei52001@gmail.com"

# 显示密码
echo "生成的密码：$PASSWORD"

# 安装Hysteria2
echo "正在安装Hysteria2..."
bash <(curl -fsSL https://get.hy2.sh/)
if [ $? -ne 0 ]; then
  echo "错误：Hysteria2安装失败。"
  exit 1
fi

# 创建Hysteria2配置文件
CONFIG_DIR="/etc/hysteria"
CONFIG_FILE="$CONFIG_DIR/config.yaml"

mkdir -p "$CONFIG_DIR"
cat << EOF > "$CONFIG_FILE"
listen: :$PORT
acme:
  domains:
    - $DOMAIN
  email: $EMAIL
auth:
  type: password
  password: $PASSWORD
masquerade:
  type: proxy
  proxy:
    url: https://news.ycombinator.com/
    rewriteHost: true
quic:
  initStreamReceiveWindow: 26843545
  maxStreamReceiveWindow: 26843545
  initConnReceiveWindow: 67108864
  maxConnReceiveWindow: 67108864
EOF

# 检查配置文件是否创建成功
if [ ! -f "$CONFIG_FILE" ]; then
  echo "错误：无法在 $CONFIG_FILE 创建配置文件。"
  exit 1
fi

# 启动并设置Hysteria2服务
echo "正在启动Hysteria2服务..."
systemctl start hysteria-server.service
if [ $? -ne 0 ]; then
  echo "错误：无法启动Hysteria2服务。"
  exit 1
fi

echo "设置Hysteria2服务开机自启..."
systemctl enable hysteria-server.service
if [ $? -ne 0 ]; then
  echo "错误：无法设置Hysteria2服务开机自启。"
  exit 1
fi

# 检查并安装qrencode
if ! command -v qrencode >/dev/null 2>&1; then
  echo "未检测到qrencode，正在尝试安装..."
  if command -v apt >/dev/null 2>&1; then
    apt update && apt install -y qrencode
  elif command -v yum >/dev/null 2>&1; then
    yum install -y epel-release && yum install -y qrencode
  else
    echo "错误：无法自动安装qrencode，请手动安装（例如：apt install qrencode 或 yum install qrencode）。"
    exit 1
  fi
  if [ $? -ne 0 ]; then
    echo "错误：qrencode安装失败，请手动安装。"
    exit 1
  fi
fi

# 生成Hysteria2节点链接
NODE_URI="hysteria2://$PASSWORD@$DOMAIN:$PORT/?insecure=0&obfs=none&sni=$DOMAIN"
echo "Hysteria2节点链接：$NODE_URI"

# 生成二维码
QR_FILE="/root/hysteria2-qr.png"
qrencode -o "$QR_FILE" "$NODE_URI"
if [ $? -eq 0 ]; then
  echo "二维码已生成：$QR_FILE"
else
  echo "错误：二维码生成失败。"
  exit 1
fi

echo "Hysteria2安装和配置成功完成！"
echo "请保存以下信息："
echo "域名：$DOMAIN"
echo "端口：$PORT"
echo "密码：$PASSWORD"
echo "节点链接：$NODE_URI"
echo "二维码文件：$QR_FILE"
