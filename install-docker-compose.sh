#!/bin/bash

# 设置错误时退出
set -e

# 检查是否以 root 权限运行
if [ "$EUID" -ne 0 ]; then 
  echo "错误: 请以 root 权限运行此脚本"
  exit 1
fi

echo "开始安装 Docker Compose..."

# 下载 Docker Compose
if ! curl -L "https://github.com/docker/compose/releases/download/v2.24.5/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose; then
    echo "错误: Docker Compose 下载失败！"
    exit 1
fi

# 添加可执行权限
if ! chmod +x /usr/local/bin/docker-compose; then
    echo "错误: 设置可执行权限失败！"
    exit 1
fi

# 验证安装
echo "验证 Docker Compose 安装..."
if ! docker-compose --version; then
    echo "错误: Docker Compose 安装验证失败！"
    echo "请检查安装是否成功完成。"
    exit 1
fi

echo "Docker Compose 安装成功完成！" 