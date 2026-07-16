#!/bin/bash

# 脚本出错时立即退出
set -e

# 将所有输出同时记录到日志文件和终端控制台，方便排查
LOG_FILE="/root/startup_script_main.log"
exec > >(tee -a "$LOG_FILE") 2>exec > "$LOG_FILE" 2>&11

echo "===== 开机脚本开始于: $(date) ====="

# --- 前置检查 ---
echo "检查网络连接..."
WAIT_COUNT=0
MAX_WAIT=12
PING_TARGET="8.8.8.8"
until ping -c 1 "$PING_TARGET" &> /dev/null
do
  if [ $WAIT_COUNT -ge $MAX_WAIT ]; then
    echo "错误：网络连接超时，无法访问 $PING_TARGET"
    exit 1
  fi
  echo "网络未就绪，等待 5 秒... ($((WAIT_COUNT+1))/$MAX_WAIT)"
  sleep 5
  WAIT_COUNT=$((WAIT_COUNT+1))
done
echo "网络连接正常。"

echo "检查 curl 是否安装..."
if ! command -v curl &> /dev/null; then
    echo "错误：未找到 curl 命令，请先安装 curl"
    exit 1
fi
echo "curl 已安装。"


# --- 安装 Docker ---
echo "检查 Docker 是否已安装..."
if ! command -v docker &> /dev/null; then
    echo "Docker 未安装，开始安装 Docker..."
    if curl -fsSL https://get.docker.com -o get-docker.sh && sh get-docker.sh; then
        echo "Docker 安装成功。"
        rm get-docker.sh
        if command -v systemctl &> /dev/null; then
            systemctl start docker
            systemctl enable docker
        fi
    else
        echo "错误：Docker 安装失败。"
        exit 1
    fi
else
    echo "Docker 已安装。"
fi


# --- 定义容器清理函数 ---
# 作用：部署前检测是否存在同名或使用同类镜像的容器，若存在则关闭并删除
cleanup_container() {
    local container_name=$1
    local image_name=$2

    echo ">>> 开始环境检测: 目标名称 [${container_name}] 或 目标镜像 [${image_name}]"
    
    # 1. 按照指定的容器名称清理
    if docker ps -a --format '{{.Names}}' | grep -Eq "^${container_name}\$"; then
        echo "发现同名容器 ${container_name}，正在停止并删除..."
        docker stop "${container_name}" >/dev/null 2>&1 || true
        docker rm "${container_name}" >/dev/null 2>&1 || true
    fi

    # 2. 按照镜像名称清理（处理可能改过名字，但镜像相同的残留容器）
    local old_ids=$(docker ps -a -q --filter "ancestor=${image_name}")
    if [ -n "$old_ids" ]; then
        echo "发现使用同类镜像 ${image_name} 的遗留容器，正在彻底清理..."
        # 遍历删除，防止多个同镜像容器存在
        for id in $old_ids; do
            docker stop "$id" >/dev/null 2>&1 || true
            docker rm "$id" >/dev/null 2>&1 || true
        done
    fi
}


# --- 架构检测与适配 ---
echo "开始检测系统架构..."
ARCH=$(uname -m)
echo "当前系统架构为: $ARCH"

if [ "$ARCH" = "x86_64" ]; then
    TM_IMAGE="traffmonetizer/cli_v2:latest"
    echo "已匹配 AMD/Intel 架构，将使用镜像: $TM_IMAGE"
elif [ "$ARCH" = "aarch64" ] || [ "$ARCH" = "arm64" ]; then
    TM_IMAGE="traffmonetizer/cli_v2:arm64v8"
    echo "已匹配 ARM64 架构，将使用镜像: $TM_IMAGE"
else
    # 针对其他罕见架构的后备方案
    TM_IMAGE="traffmonetizer/cli_v2:latest"
    echo "警告：未知的系统架构 $ARCH，将尝试使用默认镜像: $TM_IMAGE"
fi


# --- 运行 Docker 容器 ---
echo "开始配置并运行 Docker 容器..."

# 1. Traffmonetizer (自适应架构)
cleanup_container "tm" "$TM_IMAGE"
echo "运行 Traffmonetizer 容器..."
docker run -d --restart=always --name tm "$TM_IMAGE" start accept --token "WovlB9V4nql+H2MQ1FAcv6HBgy5plSrA/VRv4S25d+c="

# 2. Repocket (官方支持多架构自动拉取)
cleanup_container "repocket" "repocket/repocket"
echo "运行 Repocket 容器..."
docker run -d --restart=always -e RP_EMAIL="sijuly@outlook.com" -e RP_API_KEY="60725bcd-b4ff-4e1d-b254-e8fc6cfdf2dc" --name repocket repocket/repocket

# 3. EarnFM Client (官方支持多架构自动拉取)
cleanup_container "earnfm-client" "earnfm/earnfm-client:latest"
echo "运行 EarnFM Client 容器..."
docker run -d --restart=always -e EARNFM_TOKEN="ce203a4c-627b-4b44-934d-58689ca6cf7f" --name earnfm-client earnfm/earnfm-client:latest

# 4. Watchtower (官方支持多架构自动拉取)
cleanup_container "watchtower" "containrrr/watchtower"
echo "运行 Watchtower 容器..."
docker run -d --restart=always --name watchtower -v /var/run/docker.sock:/var/run/docker.sock containrrr/watchtower --cleanup --include-stopped --include-restarting --revive-stopped --interval 60 earnfm-client

echo "Docker 容器配置完成。"

echo "===== 开机脚本结束于: $(date) ====="
exit 0