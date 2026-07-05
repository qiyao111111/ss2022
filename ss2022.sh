#!/bin/bash

set -e

SCRIPT_NAME="SS2022 Shadowsocks-Rust 一键安装脚本"
CONTAINER_NAME="ss2022-server"
IMAGE_NAME="ghcr.io/shadowsocks/ssserver-rust:latest"
METHOD="2022-blake3-aes-128-gcm"

clear
echo "======================================"
echo " $SCRIPT_NAME"
echo " 默认协议：$METHOD"
echo " 适用于 Ubuntu / Debian"
echo "======================================"
echo ""

if [ "$(id -u)" != "0" ]; then
  echo "错误：请使用 root 用户执行"
  echo "例如：sudo bash ss2022.sh"
  exit 1
fi

check_system() {
  if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS_NAME="$ID"
  else
    echo "无法识别系统"
    exit 1
  fi

  case "$OS_NAME" in
    ubuntu|debian)
      ;;
    *)
      echo "当前系统可能不是 Ubuntu / Debian"
      echo "脚本仍会尝试继续安装"
      ;;
  esac
}

install_base_packages() {
  echo "正在安装基础依赖..."
  apt update -y
  apt install -y curl ufw net-tools iproute2 procps openssl
}

install_docker() {
  if command -v docker >/dev/null 2>&1; then
    echo "Docker 已安装"
  else
    echo "正在安装 Docker..."
    curl -fsSL https://get.docker.com | bash
  fi

  systemctl enable docker >/dev/null 2>&1 || true
  systemctl restart docker
}

random_port() {
  while true; do
    PORT=$(shuf -i 20000-60000 -n 1)
    if ! ss -lntup | grep -q ":$PORT "; then
      echo "$PORT"
      return
    fi
  done
}

random_key() {
  openssl rand -base64 16
}

get_public_ip() {
  IP=$(curl -4 -s --max-time 8 https://api.ipify.org || true)

  if [ -z "$IP" ]; then
    IP=$(curl -4 -s --max-time 8 https://ipv4.icanhazip.com || true)
  fi

  if [ -z "$IP" ]; then
    IP=$(curl -4 -s --max-time 8 https://ifconfig.me || true)
  fi

  if [ -z "$IP" ]; then
    IP=$(hostname -I | awk '{print $1}')
  fi

  echo "$IP"
}

validate_port() {
  if ! [[ "$SS_PORT" =~ ^[0-9]+$ ]]; then
    echo "错误：端口必须是数字"
    exit 1
  fi

  if [ "$SS_PORT" -lt 1 ] || [ "$SS_PORT" -gt 65535 ]; then
    echo "错误：端口范围必须是 1-65535"
    exit 1
  fi

  if ss -lntup | grep -q ":$SS_PORT "; then
    echo "错误：端口 $SS_PORT 已被占用，请换一个端口"
    exit 1
  fi
}

open_firewall() {
  echo "正在放行防火墙端口..."

  if command -v ufw >/dev/null 2>&1; then
    ufw allow "$SS_PORT"/tcp >/dev/null 2>&1 || true
    ufw allow "$SS_PORT"/udp >/dev/null 2>&1 || true
  fi

  if command -v iptables >/dev/null 2>&1; then
    iptables -I INPUT -p tcp --dport "$SS_PORT" -j ACCEPT 2>/dev/null || true
    iptables -I INPUT -p udp --dport "$SS_PORT" -j ACCEPT 2>/dev/null || true
  fi
}

remove_old_container() {
  if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    echo "检测到旧容器，正在删除..."
    docker stop "$CONTAINER_NAME" >/dev/null 2>&1 || true
    docker rm "$CONTAINER_NAME" >/dev/null 2>&1 || true
  fi
}

start_ss2022() {
  echo "正在拉取 Shadowsocks-Rust 镜像..."
  docker pull "$IMAGE_NAME"

  remove_old_container

  echo "正在启动 SS2022 服务..."

  docker run -d \
    --name "$CONTAINER_NAME" \
    --restart always \
    -p "$SS_PORT:$SS_PORT/tcp" \
    -p "$SS_PORT:$SS_PORT/udp" \
    "$IMAGE_NAME" \
    ssserver \
    -s "0.0.0.0:$SS_PORT" \
    -m "$METHOD" \
    -k "$SS_KEY" \
    --tcp-fast-open \
    -U

  sleep 2

  if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    echo "SS2022 服务启动成功"
  else
    echo "SS2022 服务启动失败，请查看日志："
    docker logs "$CONTAINER_NAME" || true
    exit 1
  fi
}

show_result() {
  IP=$(get_public_ip)

  echo ""
  echo "======================================"
  echo " SS2022 安装完成"
  echo "======================================"
  echo "服务器 IP：$IP"
  echo "端口：$SS_PORT"
  echo "加密方式：$METHOD"
  echo "密码 / 密钥：$SS_KEY"
  echo ""
  echo "Shadowrocket 手动填写："
  echo "类型：Shadowsocks"
  echo "服务器：$IP"
  echo "端口：$SS_PORT"
  echo "加密方式：$METHOD"
  echo "密码：$SS_KEY"
  echo ""
  echo "SS URI："
  SS_USERINFO=$(printf "%s:%s" "$METHOD" "$SS_KEY" | base64 -w 0 2>/dev/null || printf "%s:%s" "$METHOD" "$SS_KEY" | base64 | tr -d '\n')
  echo "ss://$SS_USERINFO@$IP:$SS_PORT#SS2022-$IP"
  echo ""
  echo "Clash 配置："
  echo "- name: SS2022-$IP"
  echo "  type: ss"
  echo "  server: $IP"
  echo "  port: $SS_PORT"
  echo "  cipher: $METHOD"
  echo "  password: $SS_KEY"
  echo "  udp: true"
  echo ""
  echo "管理命令："
  echo "docker ps | grep $CONTAINER_NAME"
  echo "docker logs $CONTAINER_NAME"
  echo "docker restart $CONTAINER_NAME"
  echo "docker stop $CONTAINER_NAME"
  echo ""
  echo "开机自启：已开启"
  echo "======================================"
}

install_ss2022() {
  check_system
  install_base_packages
  install_docker

  echo ""
  echo "请选择安装模式："
  echo "1) 自定义端口 / 自定义密钥"
  echo "2) 随机生成端口 / 随机密钥"
  echo ""

  read -p "请输入选项 [1/2]，默认 2: " MODE
  MODE=${MODE:-2}

  if [ "$MODE" = "1" ]; then
    read -p "请输入 SS2022 端口，例如 443 或 12000: " SS_PORT
    echo ""
    echo "注意：SS2022 的密码建议使用 base64 密钥。"
    echo "如果你不懂，建议直接回车，让脚本自动生成安全密钥。"
    read -p "请输入自定义密钥，留空则自动生成: " SS_KEY

    if [ -z "$SS_KEY" ]; then
      SS_KEY=$(random_key)
    fi
  else
    SS_PORT=$(random_port)
    SS_KEY=$(random_key)
  fi

  if [ -z "$SS_PORT" ] || [ -z "$SS_KEY" ]; then
    echo "错误：端口和密钥不能为空"
    exit 1
  fi

  validate_port
  open_firewall
  start_ss2022
  show_result
}

show_status() {
  echo "======================================"
  echo " SS2022 服务状态"
  echo "======================================"

  if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    docker ps -a | grep "$CONTAINER_NAME" || true
    echo ""
    echo "最近日志："
    docker logs --tail 50 "$CONTAINER_NAME" || true
  else
    echo "未找到 SS2022 容器"
  fi
}

restart_ss2022() {
  echo "正在重启 SS2022..."
  docker restart "$CONTAINER_NAME"

  echo "重启完成"
  docker ps | grep "$CONTAINER_NAME" || true
}

uninstall_ss2022() {
  echo "警告：即将卸载 SS2022 容器"
  read -p "确认卸载吗？输入 y 确认: " CONFIRM

  if [ "$CONFIRM" != "y" ]; then
    echo "已取消卸载"
    exit 0
  fi

  docker stop "$CONTAINER_NAME" >/dev/null 2>&1 || true
  docker rm "$CONTAINER_NAME" >/dev/null 2>&1 || true

  echo "SS2022 容器已卸载"
  echo "Docker 本身没有卸载，避免影响你其他服务。"
}

main_menu() {
  echo "请选择操作："
  echo "1) 安装 / 重装 SS2022"
  echo "2) 查看状态"
  echo "3) 重启服务"
  echo "4) 卸载 SS2022"
  echo ""

  read -p "请输入选项 [1/2/3/4]，默认 1: " ACTION
  ACTION=${ACTION:-1}

  case "$ACTION" in
    1)
      install_ss2022
      ;;
    2)
      show_status
      ;;
    3)
      restart_ss2022
      ;;
    4)
      uninstall_ss2022
      ;;
    *)
      echo "无效选项"
      exit 1
      ;;
  esac
}

main_menu
