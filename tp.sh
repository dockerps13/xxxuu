#!/usr/bin/env bash
# Debian 11 / BBRplus 自动网络优化脚本
set -euo pipefail

# 自动检测第一个非 lo 网卡
IFACE=$(ip -o link show | awk -F': ' '$2!="lo"{print $2; exit}')
echo "[INFO] 检测到网卡接口: $IFACE"

# 写入系统优化参数
cat >/etc/sysctl.d/99-bbrplus-opt.conf <<'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbrplus
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.ipv4.tcp_rmem = 4096 87380 134217728
net.ipv4.tcp_wmem = 4096 65536 134217728
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_low_latency = 1
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_fin_timeout = 10
net.ipv4.tcp_keepalive_time = 120
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 3
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_max_tw_buckets = 2000000
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_slow_start_after_idle = 0
fs.file-max = 1200000
net.core.somaxconn = 4096
net.core.netdev_max_backlog = 32768

# 内存管理参数优化
vm.swappiness = 10
vm.dirty_ratio = 40
vm.dirty_background_ratio = 10

# 防火墙连接跟踪表最大值
net.netfilter.nf_conntrack_max = 1048576

# 启用 TCP BPF 过滤
net.ipv4.tcp_bpf = 1

EOF

# 检查内核是否支持 BBRplus
if ! sysctl -n net.ipv4.tcp_congestion_control | grep -q 'bbrplus'; then
  echo "[INFO] BBRplus 不受支持，使用 BBR 替代"
  sed -i 's/net.ipv4.tcp_congestion_control = bbrplus/net.ipv4.tcp_congestion_control = bbr/' /etc/sysctl.d/99-bbrplus-opt.conf
fi

sysctl --system

# 应用 FQ 队列
tc qdisc del dev "$IFACE" root 2>/dev/null || true
tc qdisc add dev "$IFACE" root fq limit 20000 flow_limit 200

# 网卡加速特性
apt-get update -y >/dev/null 2>&1 || true
apt-get install -y ethtool >/dev/null 2>&1 || true
ethtool -K "$IFACE" tso on gso on gro on 2>/dev/null || true

# 文件句柄
if ! grep -q '1048576' /etc/security/limits.conf 2>/dev/null; then
  echo '* soft nofile 1048576' >>/etc/security/limits.conf
  echo '* hard nofile 1048576' >>/etc/security/limits.conf
fi

# 最大进程数和连接数
echo '* soft nproc 65535' >> /etc/security/limits.conf
echo '* hard nproc 65535' >> /etc/security/limits.conf

# 创建 systemd 自启动服务，开机自动识别网卡并启用 FQ
cat >/etc/systemd/system/fqsetup.service <<'EOF'
[Unit]
Description=Set FQ qdisc automatically after network online
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/bin/bash -c '\
IFACE=$(ip -o link show | awk -F": " "$2!=\"lo\"{print $2; exit}"); \
if [ -n "$IFACE" ]; then \
    /sbin/tc qdisc del dev "$IFACE" root 2>/dev/null; \
    /sbin/tc qdisc add dev "$IFACE" root fq limit 20000 flow_limit 200; \
    /sbin/ethtool -K "$IFACE" tso on gso on gro on 2>/dev/null || true; \
    logger -t fqsetup "Applied fq on $IFACE"; \
else \
    logger -t fqsetup "No network interface found"; \
fi'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable fqsetup.service
systemctl start fqsetup.service

# 日志管理（轮换日志）
cat > /etc/logrotate.d/vpn_logs <<'EOF'
/var/log/vpn.log {
    daily
    rotate 7
    compress
    missingok
    notifempty
}
EOF

# 提示完成
echo
echo "✅ BBRplus 自动优化完成"
sysctl net.ipv4.tcp_congestion_control
tc qdisc show dev "$IFACE" | head -n 2
echo
echo "重启后 systemd 将自动识别网卡并启用 fq + BBRplus。"

# 提示日志轮换配置
echo "✅ VPN 日志轮换配置完成。"
