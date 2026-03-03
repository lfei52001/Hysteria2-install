#!/bin/bash

# ============================================================
#  Hysteria 2 一键部署脚本
#  支持系统: Debian 12 / Ubuntu 22.04+
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

HY2_CONFIG="/etc/hysteria/config.yaml"
HY2_BIN="/usr/local/bin/hysteria"
HY2_SERVICE="hysteria-server"
CERT_DIR="/etc/hysteria/certs"

# ============================================================
# 工具函数
# ============================================================

info()    { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; }
success() { echo -e "${GREEN}[✓]${NC} $*"; }
step()    { echo -e "${CYAN}[*]${NC} $*"; }

check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "请使用 root 权限运行此脚本！"
        exit 1
    fi
}

press_any_key() {
    echo ""
    read -rp "按 Enter 键返回主菜单..." _
}

# ============================================================
# 安装 Hysteria 2
# ============================================================

install_hysteria2() {
    step "安装 Hysteria 2..."
    apt-get update -qq
    apt-get install -y -qq curl openssl

    bash <(curl -fsSL https://get.hy2.sh/)
    if [[ $? -ne 0 ]]; then
        error "Hysteria 2 安装失败，请检查网络连接！"
        return 1
    fi
    success "Hysteria 2 安装完成"
    hysteria version 2>/dev/null | head -1
}

# ============================================================
# 更新 Hysteria 2
# ============================================================

update_hysteria2() {
    step "更新 Hysteria 2..."
    bash <(curl -fsSL https://get.hy2.sh/)
    if [[ $? -eq 0 ]]; then
        systemctl restart "$HY2_SERVICE" 2>/dev/null
        success "更新完成！当前版本: $(hysteria version 2>/dev/null | head -1)"
    else
        error "更新失败，请检查网络连接！"
    fi
}

# ============================================================
# 证书处理（自签 / ACME 自动申请）
# ============================================================

setup_cert() {
    local domain="$1"   # 若为 IP 模式则为空
    local server_addr="$2"

    mkdir -p "$CERT_DIR"

    if [[ -n "$domain" ]]; then
        # ── ACME 自动申请证书 ──────────────────────────────
        echo ""
        echo -e "${CYAN}证书申请方式：${NC}"
        echo -e "  ${BOLD}1.${NC} ACME 自动申请 Let's Encrypt 证书（需要域名已解析到本机）"
        echo -e "  ${BOLD}2.${NC} 使用自签证书（客户端需开启跳过证书验证）"
        read -rp "$(echo -e "${CYAN}请选择 [默认 1]:${NC} ")" CERT_CHOICE
        CERT_CHOICE="${CERT_CHOICE:-1}"

        if [[ "$CERT_CHOICE" == "1" ]]; then
            read -rp "$(echo -e "${CYAN}请输入申请证书的邮箱:${NC} ")" ACME_EMAIL
            if [[ -z "$ACME_EMAIL" ]]; then
                ACME_EMAIL="admin@${domain}"
                warn "未输入邮箱，使用默认: ${ACME_EMAIL}"
            fi
            CERT_MODE="acme"
            CERT_DOMAIN="$domain"
            CERT_EMAIL="$ACME_EMAIL"
            CERT_KEY=""
            CERT_CRT=""
            success "将使用 ACME 自动申请证书，域名: ${domain}"
            return 0
        fi
    fi

    # ── 自签证书 ───────────────────────────────────────────
    step "生成自签证书..."
    local cn="${domain:-$server_addr}"
    openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:P-256 \
        -keyout "${CERT_DIR}/private.key" \
        -out    "${CERT_DIR}/cert.crt"   \
        -days 3650 -subj "/CN=${cn}"     \
        2>/dev/null

    if [[ $? -ne 0 ]]; then
        error "自签证书生成失败！"
        return 1
    fi
    # 授予 hysteria 服务用户读取权限
    chmod 644 "${CERT_DIR}/cert.crt"
    chmod 640 "${CERT_DIR}/private.key"
    chown -R root:root "${CERT_DIR}"
    chmod 755 "${CERT_DIR}"
    # hysteria-server 默认以 nobody 用户运行，需要可读
    if id "hysteria" &>/dev/null; then
        chown root:hysteria "${CERT_DIR}/private.key"
    else
        chmod 644 "${CERT_DIR}/private.key"
    fi
    CERT_MODE="self"
    CERT_KEY="${CERT_DIR}/private.key"
    CERT_CRT="${CERT_DIR}/cert.crt"
    success "自签证书已生成: ${CERT_DIR}/"
}

# ============================================================
# 生成配置文件
# ============================================================

generate_config() {
    local port="$1"
    local password="$2"
    local domain="$3"     # 域名，ACME 模式下有值
    local cert_mode="$4"  # acme / self

    mkdir -p /etc/hysteria

    if [[ "$cert_mode" == "acme" ]]; then
        cat > "$HY2_CONFIG" <<EOF
listen: :${port}

acme:
  domains:
    - ${domain}
  email: ${CERT_EMAIL}

auth:
  type: password
  password: ${password}

masquerade:
  type: proxy
  proxy:
    url: https://news.ycombinator.com/
    rewriteHost: true

bandwidth:
  up: 1 gbps
  down: 1 gbps
EOF
    else
        cat > "$HY2_CONFIG" <<EOF
listen: :${port}

tls:
  cert: ${CERT_CRT}
  key: ${CERT_KEY}

auth:
  type: password
  password: ${password}

masquerade:
  type: proxy
  proxy:
    url: https://news.ycombinator.com/
    rewriteHost: true

bandwidth:
  up: 1 gbps
  down: 1 gbps
EOF
    fi
}

# ============================================================
# 打印客户端配置信息
# ============================================================

print_client_info() {
    local server_addr="$1"
    local port="$2"
    local password="$3"
    local cert_mode="$4"
    local domain="$5"

    # insecure 仅自签模式需要
    local insecure="0"
    local sni_field="$server_addr"
    if [[ "$cert_mode" == "self" ]]; then
        insecure="1"
        sni_field="${domain:-$server_addr}"
    else
        sni_field="$domain"
    fi

    echo ""
    echo -e "${BOLD}${BLUE}╔══════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${BLUE}║         Hysteria 2 节点配置信息               ║${NC}"
    echo -e "${BOLD}${BLUE}╚══════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  ${CYAN}协议${NC}            : Hysteria 2"
    echo -e "  ${CYAN}服务器地址${NC}      : ${BOLD}${server_addr}${NC}"
    echo -e "  ${CYAN}端口${NC}            : ${BOLD}${port}${NC}"
    echo -e "  ${CYAN}密码${NC}            : ${BOLD}${password}${NC}"
    echo -e "  ${CYAN}TLS SNI${NC}         : ${BOLD}${sni_field}${NC}"
    if [[ "$cert_mode" == "self" ]]; then
        echo -e "  ${CYAN}跳过证书验证${NC}    : ${BOLD}${YELLOW}是（自签证书）${NC}"
    else
        echo -e "  ${CYAN}证书${NC}            : ${BOLD}Let's Encrypt（正规证书）${NC}"
    fi
    echo ""

    # 生成 hysteria2:// 分享链接
    local share_link
    if [[ "$cert_mode" == "self" ]]; then
        share_link="hysteria2://${password}@${server_addr}:${port}?insecure=1&sni=${sni_field}#Hysteria2-Node"
    else
        share_link="hysteria2://${password}@${server_addr}:${port}?sni=${sni_field}#Hysteria2-Node"
    fi

    echo -e "${BOLD}${GREEN}分享链接:${NC}"
    echo -e "${YELLOW}${share_link}${NC}"
    echo ""

    # 客户端 YAML 配置片段
    echo -e "${BOLD}${GREEN}客户端配置 (YAML):${NC}"
    if [[ "$cert_mode" == "self" ]]; then
        echo -e "${CYAN}server: ${server_addr}:${port}
auth: ${password}
tls:
  sni: ${sni_field}
  insecure: true
bandwidth:
  up: 50 mbps
  down: 200 mbps${NC}"
    else
        echo -e "${CYAN}server: ${server_addr}:${port}
auth: ${password}
tls:
  sni: ${sni_field}
bandwidth:
  up: 50 mbps
  down: 200 mbps${NC}"
    fi
    echo ""

    # 保存到文件
    local save_path="/root/hysteria2_client_info.txt"
    {
        echo "===== Hysteria 2 节点配置信息 ====="
        echo "服务器地址   : ${server_addr}"
        echo "端口         : ${port}"
        echo "密码         : ${password}"
        echo "TLS SNI      : ${sni_field}"
        if [[ "$cert_mode" == "self" ]]; then
            echo "跳过证书验证 : 是（自签证书）"
        else
            echo "证书         : Let's Encrypt"
        fi
        echo ""
        echo "分享链接:"
        echo "${share_link}"
        echo ""
        echo "客户端配置 (YAML):"
        if [[ "$cert_mode" == "self" ]]; then
            echo "server: ${server_addr}:${port}"
            echo "auth: ${password}"
            echo "tls:"
            echo "  sni: ${sni_field}"
            echo "  insecure: true"
            echo "bandwidth:"
            echo "  up: 50 mbps"
            echo "  down: 200 mbps"
        else
            echo "server: ${server_addr}:${port}"
            echo "auth: ${password}"
            echo "tls:"
            echo "  sni: ${sni_field}"
            echo "bandwidth:"
            echo "  up: 50 mbps"
            echo "  down: 200 mbps"
        fi
    } > "$save_path"

    success "配置信息已保存至 ${BOLD}${save_path}${NC}"
}

# ============================================================
# 功能 1：一键搭建 Hysteria 2 节点
# ============================================================

setup_hysteria2() {
    echo ""
    echo -e "${BOLD}${GREEN}═══════════ 一键搭建 Hysteria 2 节点 ═══════════${NC}"
    echo ""
    check_root

    # ── 1. 获取服务器公网 IP ──
    step "获取服务器公网 IP..."
    SERVER_IP=$(curl -s --max-time 6 https://api4.ipify.org 2>/dev/null)
    if [[ -z "$SERVER_IP" ]]; then
        SERVER_IP=$(curl -s --max-time 6 https://ifconfig.me 2>/dev/null)
    fi
    if [[ -z "$SERVER_IP" ]]; then
        SERVER_IP=$(curl -s --max-time 6 https://ipinfo.io/ip 2>/dev/null)
    fi
    info "检测到服务器公网 IP: ${BOLD}${SERVER_IP}${NC}"

    # ── 2. 选择连接地址（IP 或域名）──
    echo ""
    echo -e "${CYAN}客户端连接地址选择：${NC}"
    echo -e "  ${BOLD}1.${NC} 使用公网 IP  (${SERVER_IP})"
    echo -e "  ${BOLD}2.${NC} 使用解析到此 VPS 的域名"
    read -rp "$(echo -e "${CYAN}请选择 [默认 1]:${NC} ")" ADDR_CHOICE
    ADDR_CHOICE="${ADDR_CHOICE:-1}"

    INPUT_DOMAIN=""
    if [[ "$ADDR_CHOICE" == "2" ]]; then
        echo ""
        while true; do
            read -rp "$(echo -e "${CYAN}请输入域名（如 vps.example.com）:${NC} ")" INPUT_DOMAIN
            INPUT_DOMAIN=$(echo "$INPUT_DOMAIN" | tr -d '[:space:]' | sed 's|https*://||g' | sed 's|/.*||g')
            if [[ -z "$INPUT_DOMAIN" ]]; then
                warn "域名不能为空，请重新输入。"
                continue
            fi
            if ! echo "$INPUT_DOMAIN" | grep -qP '^[a-zA-Z0-9]([a-zA-Z0-9.\-]*[a-zA-Z0-9])?$'; then
                warn "域名格式不正确，请重新输入。"
                continue
            fi
            step "正在解析域名 ${INPUT_DOMAIN}..."
            RESOLVED_IP=$(getent hosts "$INPUT_DOMAIN" 2>/dev/null | awk '{print $1}' | head -1)
            if [[ -z "$RESOLVED_IP" ]]; then
                RESOLVED_IP=$(dig +short "$INPUT_DOMAIN" 2>/dev/null | tail -1)
            fi
            if [[ -n "$RESOLVED_IP" ]]; then
                info "域名解析结果: ${RESOLVED_IP}"
                if [[ "$RESOLVED_IP" == "$SERVER_IP" ]]; then
                    success "域名已正确解析到本机 IP"
                else
                    warn "域名解析到 ${RESOLVED_IP}，与本机 IP ${SERVER_IP} 不一致"
                    read -rp "$(echo -e "${YELLOW}是否仍然使用此域名？(y/N):${NC} ")" FORCE_DOMAIN
                    if [[ "$FORCE_DOMAIN" != "y" && "$FORCE_DOMAIN" != "Y" ]]; then
                        continue
                    fi
                fi
            else
                warn "无法解析域名 ${INPUT_DOMAIN}"
                read -rp "$(echo -e "${YELLOW}是否仍然使用此域名？(y/N):${NC} ")" FORCE_DOMAIN
                if [[ "$FORCE_DOMAIN" != "y" && "$FORCE_DOMAIN" != "Y" ]]; then
                    continue
                fi
            fi
            SERVER_ADDR="$INPUT_DOMAIN"
            break
        done
    else
        SERVER_ADDR="$SERVER_IP"
    fi
    info "客户端连接地址: ${BOLD}${SERVER_ADDR}${NC}"

    # ── 3. 输入端口 ──
    echo ""
    read -rp "$(echo -e "${CYAN}请输入监听端口 [默认 443]:${NC} ")" INPUT_PORT
    INPUT_PORT="${INPUT_PORT:-443}"
    if ! [[ "$INPUT_PORT" =~ ^[0-9]+$ ]] || [[ "$INPUT_PORT" -lt 1 || "$INPUT_PORT" -gt 65535 ]]; then
        error "端口号无效，请输入 1-65535 之间的数字！"
        press_any_key
        return 1
    fi
    info "使用端口: ${BOLD}${INPUT_PORT}${NC}"

    # ── 4. 生成随机密码 ──
    echo ""
    step "生成随机连接密码..."
    HY2_PASSWORD=$(openssl rand -base64 24 | tr -d '=+/' | cut -c1-20)
    success "连接密码: ${BOLD}${HY2_PASSWORD}${NC}"

    # ── 5. 证书配置 ──
    echo ""
    setup_cert "$INPUT_DOMAIN" "$SERVER_ADDR" || { press_any_key; return 1; }

    # ── 6. 安装 Hysteria 2 ──
    echo ""
    install_hysteria2 || { press_any_key; return 1; }

    # ── 7. 写入配置 ──
    echo ""
    step "生成配置文件..."
    generate_config "$INPUT_PORT" "$HY2_PASSWORD" "$INPUT_DOMAIN" "$CERT_MODE"
    success "配置文件已写入 ${HY2_CONFIG}"

    # ── 8. 启动服务 ──
    echo ""
    step "启动 Hysteria 2 服务..."
    systemctl enable "$HY2_SERVICE" --quiet 2>/dev/null
    systemctl restart "$HY2_SERVICE"

    sleep 2
    if systemctl is-active --quiet "$HY2_SERVICE"; then
        success "Hysteria 2 服务运行正常！"
    else
        error "Hysteria 2 服务启动失败，查看日志："
        journalctl -u "$HY2_SERVICE" -n 30 --no-pager
        press_any_key
        return 1
    fi

    # ── 9. 打印客户端信息 ──
    print_client_info "$SERVER_ADDR" "$INPUT_PORT" "$HY2_PASSWORD" "$CERT_MODE" "$INPUT_DOMAIN"

    press_any_key
}

# ============================================================
# 功能 2：更新 Hysteria 2
# ============================================================

do_update() {
    echo ""
    echo -e "${BOLD}${GREEN}═══════════ 更新 Hysteria 2 ═══════════${NC}"
    echo ""
    check_root

    if [[ ! -f "$HY2_BIN" ]]; then
        warn "Hysteria 2 未安装，将直接安装最新版..."
    else
        info "当前版本: $(hysteria version 2>/dev/null | head -1)"
    fi

    update_hysteria2
    press_any_key
}

# ============================================================
# 功能 3：移除 Hysteria 2 节点
# ============================================================

remove_hysteria2() {
    echo ""
    echo -e "${BOLD}${RED}═══════════ 移除 Hysteria 2 节点 ═══════════${NC}"
    echo ""
    check_root

    read -rp "$(echo -e "${RED}确认移除 Hysteria 2 节点及所有配置？(y/N):${NC} ")" CONFIRM
    if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
        info "已取消操作。"
        press_any_key
        return
    fi

    step "停止并禁用服务..."
    systemctl stop "$HY2_SERVICE"    2>/dev/null
    systemctl disable "$HY2_SERVICE" 2>/dev/null

    step "卸载 Hysteria 2..."
    bash <(curl -fsSL https://get.hy2.sh/) --remove 2>/dev/null

    step "清理配置及证书文件..."
    rm -rf /etc/hysteria
    rm -f  /root/hysteria2_client_info.txt

    success "Hysteria 2 节点已完全移除！"
    press_any_key
}

# ============================================================
# 功能 4：查看节点信息
# ============================================================

show_info() {
    echo ""
    echo -e "${BOLD}${GREEN}═══════════ 当前节点信息 ═══════════${NC}"
    echo ""

    if [[ ! -f "$HY2_CONFIG" ]]; then
        warn "未找到配置文件，节点可能尚未搭建。"
        press_any_key
        return
    fi

    if [[ -f /root/hysteria2_client_info.txt ]]; then
        cat /root/hysteria2_client_info.txt
    else
        info "配置文件内容："
        cat "$HY2_CONFIG"
    fi

    echo ""
    echo -e "${CYAN}服务状态:${NC}"
    systemctl status "$HY2_SERVICE" --no-pager -l | head -20

    press_any_key
}

# ============================================================
# 功能 5：删除脚本自身
# ============================================================

delete_script() {
    echo ""
    echo -e "${BOLD}${RED}═══════════ 删除脚本 ═══════════${NC}"
    echo ""

    SCRIPT_PATH=$(realpath "$0" 2>/dev/null || echo "$0")
    info "脚本路径: ${SCRIPT_PATH}"
    echo ""
    read -rp "$(echo -e "${RED}确认删除此脚本文件？(y/N):${NC} ")" CONFIRM
    if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
        info "已取消操作。"
        press_any_key
        return
    fi

    rm -f "$SCRIPT_PATH"
    success "脚本已删除：${SCRIPT_PATH}"
    echo ""
    info "退出脚本..."
    sleep 1
    exit 0
}

# ============================================================
# 主菜单
# ============================================================

show_menu() {
    clear
    echo ""
    echo -e "${BOLD}${BLUE}  ╔══════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${BLUE}  ║      Hysteria 2  节点管理脚本            ║${NC}"
    echo -e "${BOLD}${BLUE}  ║        Debian 12 / Ubuntu 22.04+         ║${NC}"
    echo -e "${BOLD}${BLUE}  ╚══════════════════════════════════════════╝${NC}"
    echo ""

    # 显示服务运行状态
    if systemctl is-active --quiet "$HY2_SERVICE" 2>/dev/null; then
        echo -e "  Hysteria 2 状态: ${GREEN}● 运行中${NC}"
    elif [[ -f "$HY2_BIN" ]]; then
        echo -e "  Hysteria 2 状态: ${RED}● 已停止${NC}"
    else
        echo -e "  Hysteria 2 状态: ${YELLOW}● 未安装${NC}"
    fi

    echo ""
    echo -e "  ${BOLD}1.${NC} 一键搭建 Hysteria 2 节点"
    echo -e "  ${BOLD}2.${NC} 更新 Hysteria 2"
    echo -e "  ${BOLD}3.${NC} 移除 Hysteria 2 节点"
    echo -e "  ${BOLD}4.${NC} 查看节点信息"
    echo -e "  ${BOLD}5.${NC} 退出脚本"
    echo -e "  ${BOLD}6.${NC} 删除脚本"
    echo ""
    echo -e "${BLUE}══════════════════════════════════════════════${NC}"
}

main() {
    check_root

    while true; do
        show_menu
        read -rp "$(echo -e "${CYAN}请输入选项 [1-6]:${NC} ")" CHOICE
        case "$CHOICE" in
            1) setup_hysteria2 ;;
            2) do_update       ;;
            3) remove_hysteria2 ;;
            4) show_info       ;;
            5)
                echo ""
                info "已退出脚本，再见！"
                echo ""
                exit 0
                ;;
            6) delete_script ;;
            *)
                warn "无效选项，请输入 1-6"
                sleep 1
                ;;
        esac
    done
}

main
