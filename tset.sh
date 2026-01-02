#!/usr/bin/env bash
# 整合版 PVE 硬件监控脚本 (修复图表显示问题)
# version: 2026.1.3-fix

set -euo pipefail

# 颜色定义
RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
NC='\033[0m'

# 配置项
ENABLE_NVME_INFO=true
ENABLE_SATA_INFO=true
DEBUG_MODE=false

# -------------------- 前置检查 --------------------
# 必须为 root 用户
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}⛔ 请以 root 身份运行此脚本!${NC}"
    exit 1
fi

# 必须是 PVE 环境
if ! command -v pveversion &> /dev/null; then
    echo -e "${RED}⛔ 未检测到 ProxmoxVE 环境, 停止执行!${NC}"
    exit 1
fi

# 确认执行
read -p "$(echo -e "${YELLOW}确认执行吗? [y/N]:${NC}")" para
[[ "$para" =~ ^[Yy]$ ]] || {
    echo -e "${YELLOW}\n🚫 操作取消, 未执行任何操作!${NC}"
    exit 0
}

# -------------------- 变量定义 --------------------
PVE_VERSION=$(pveversion | awk -F"/" '{print $2}')
NODES_PM="/usr/share/perl5/PVE/API2/Nodes.pm"
PVE_MANAGER_JS="/usr/share/pve-manager/js/pvemanagerlib.js"
PROXMOX_LIB_JS="/usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js"
BACKUP_SUFFIX=".${PVE_VERSION}.bak"

# -------------------- 备份文件 --------------------
echo -e "\n${BLUE}💾 备份原始文件...${NC}"
backup_file() {
    local file=$1
    if [ ! -f "${file}${BACKUP_SUFFIX}" ]; then
        cp "$file" "${file}${BACKUP_SUFFIX}"
        echo -e "${GREEN}✅ 已备份: ${file}${BACKUP_SUFFIX}${NC}"
    else
        echo -e "${YELLOW}⚠️  备份文件已存在, 跳过: ${file}${BACKUP_SUFFIX}${NC}"
    fi
}

backup_file "$NODES_PM"
backup_file "$PVE_MANAGER_JS"
backup_file "$PROXMOX_LIB_JS"

# -------------------- 安装依赖 --------------------
echo -e "\n${BLUE}🗃️ 安装必要依赖...${NC}"
REQUIRED_PACKAGES=(sudo sysstat lm-sensors smartmontools linux-cpupower hdparm)
missing_pkgs=()

for pkg in "${REQUIRED_PACKAGES[@]}"; do
    if ! dpkg -s "$pkg" &> /dev/null; then
        missing_pkgs+=("$pkg")
    fi
done

if [ ${#missing_pkgs[@]} -gt 0 ]; then
    apt-get update -y
    apt-get install -y "${missing_pkgs[@]}"
    echo -e "${GREEN}✅ 已安装缺失依赖: ${missing_pkgs[*]}${NC}"
else
    echo -e "${GREEN}✅ 所有依赖已安装${NC}"
fi

# 配置传感器
echo -e "\n${BLUE}🧰 配置传感器模块...${NC}"
sensors-detect --auto > /tmp/sensors 2>&1 || true
modprobe msr || true
echo "msr" > /etc/modules-load.d/turbostat-msr.conf

# -------------------- 配置 sudo 权限 (安全版本) --------------------
echo -e "\n${BLUE}🔩 配置 sudo 权限...${NC}"
SUDOERS_FILE="/etc/sudoers.d/pve-hardware-monitor"
cat > "$SUDOERS_FILE" << EOF
# PVE 硬件监控所需权限
www-data ALL=(root) NOPASSWD: $(command -v sensors)
www-data ALL=(root) NOPASSWD: $(command -v smartctl) -a /dev/*
www-data ALL=(root) NOPASSWD: $(command -v turbostat) -S -q -s PkgWatt -i 0.1 -n 1 -c package
www-data ALL=(root) NOPASSWD: $(command -v hdparm) -C /dev/sd*
EOF

chmod 0440 "$SUDOERS_FILE"
chown root:root "$SUDOERS_FILE"
visudo -c -f "$SUDOERS_FILE" &> /dev/null || {
    echo -e "${RED}⛔ sudoers 配置错误!${NC}"
    rm -f "$SUDOERS_FILE"
    exit 1
}

# -------------------- 修改 Nodes.pm (核心API) --------------------
echo -e "\n${BLUE}📝 修改 Nodes.pm (API 数据接口)...${NC}"

# 先清理旧的修改内容
sed -i '/modbyshowtempfreq/d' "$NODES_PM"
sed -i '/cpupower/d' "$NODES_PM"
sed -i '/cpufreq/d' "$NODES_PM"
sed -i '/sensors/d' "$NODES_PM"
sed -i '/thermalstate/d' "$NODES_PM"
sed -i '/cpuFreq/d' "$NODES_PM"
sed -i '/nvme[0-9]/d' "$NODES_PM"
sed -i '/sd[0-9]/d' "$NODES_PM"

# 插入统一的监控数据代码 (避免冲突)
cat > /tmp/pve_hw_monitor.tmp << 'EOF'
        # 硬件监控数据 (整合版)
        $res->{hwmonitor} = {
            # CPU 基础信息
            cpu_governor => `cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo "unknown"`,
            cpu_power => `sudo turbostat -S -q -s PkgWatt -i 0.1 -n 1 -c package 2>/dev/null | grep -v PkgWatt || echo "0"`,
            cpu_freq => `cat /proc/cpuinfo | grep -i "cpu mhz" | head -1 | awk '{print $4}' || echo "0"`,
            cpu_freq_min => `cat /sys/devices/system/cpu/cpufreq/policy0/cpuinfo_min_freq 2>/dev/null | awk '{print $1/1000}' || echo "0"`,
            cpu_freq_max => `cat /sys/devices/system/cpu/cpufreq/policy0/cpuinfo_max_freq 2>/dev/null | awk '{print $1/1000}' || echo "0"`,
            
            # 温度传感器
            sensors => `sudo sensors -A 2>/dev/null`,
            
            # CPU 核心频率
            core_freqs => `cat /proc/cpuinfo | grep -i "cpu mhz" | awk '{print $4}'`
        };

        # NVME 硬盘信息
EOF

# 添加 NVME 硬盘信息
if $ENABLE_NVME_INFO; then
    nvi=0
    for nvme in $(ls /dev/nvme[0-9] 2> /dev/null); do
        cat >> /tmp/pve_hw_monitor.tmp << EOF
        \$res->{hwmonitor}->{nvme${nvi}} = \`sudo smartctl $nvme -a -j 2>/dev/null || echo '{"error":"no data"}'\`;
EOF
        nvi=$((nvi+1))
    done
fi

# 添加 SATA 硬盘信息
cat >> /tmp/pve_hw_monitor.tmp << 'EOF'
        # SATA 硬盘信息
EOF

if $ENABLE_SATA_INFO; then
    sdi=0
    for sd in $(ls /dev/sd[a-z] 2> /dev/null); do
        sdsn=$(basename "$sd")
        cat >> /tmp/pve_hw_monitor.tmp << EOF
        \$res->{hwmonitor}->{sd${sdi}} = \`
            if [ -b $sd ]; then
                if [ "\$(cat /sys/block/$sdsn/queue/rotational 2>/dev/null)" = "1" ] && sudo hdparm -C $sd 2>/dev/null | grep -iq 'standby'; then
                    echo '{"standby":true}'
                else
                    sudo smartctl $sd -a -j 2>/dev/null || echo '{"error":"no data"}'
                fi
            else
                echo '{"error":"not found"}'
            fi
        \`;
EOF
        sdi=$((sdi+1))
    done
fi

# 插入到正确位置 (不干扰原有API逻辑)
if grep -q 'PVE::pvecfg::version_text' "$NODES_PM"; then
    sed -i "/PVE::pvecfg::version_text/ r /tmp/pve_hw_monitor.tmp" "$NODES_PM"
    echo -e "${GREEN}✅ Nodes.pm 修改完成${NC}"
else
    echo -e "${RED}⛔ Nodes.pm 锚点未找到!${NC}"
    exit 1
fi

rm -f /tmp/pve_hw_monitor.tmp

# -------------------- 修改 pvemanagerlib.js (前端显示) --------------------
echo -e "\n${BLUE}📝 修改 pvemanagerlib.js (前端界面)...${NC}"

# 先清理旧的修改内容
sed -i '/modbyshowtempfreq/d' "$PVE_MANAGER_JS"
sed -i '/itemId: 'cpupower'/d' "$PVE_MANAGER_JS"
sed -i '/itemId: 'cpufreq'/d' "$PVE_MANAGER_JS"
sed -i '/itemId: 'sensors'/d' "$PVE_MANAGER_JS"
sed -i '/itemId: 'corefreq'/d' "$PVE_MANAGER_JS"
sed -i '/itemId: 'thermal'/d' "$PVE_MANAGER_JS"
sed -i '/itemId: 'nvme/d' "$PVE_MANAGER_JS"
sed -i '/itemId: 'sd/d' "$PVE_MANAGER_JS"

# 插入整合的前端渲染代码
cat > /tmp/pve_hw_frontend.tmp << 'EOF'
        // 硬件监控面板 (整合版 - 不影响图表)
        {
            itemId: 'hw_cpu',
            colspan: 2,
            printBar: false,
            title: gettext('CPU 信息'),
            textField: 'hwmonitor',
            renderer: function(value) {
                // CPU 模式颜色
                function getGovernorColor(governor) {
                    switch(governor.trim()) {
                        case 'powersave': return 'green';
                        case 'performance': return 'red';
                        default: return 'orange';
                    }
                }
                // 频率颜色
                function getFreqColor(freq) {
                    freq = parseFloat(freq);
                    if (freq < 1500) return 'green';
                    if (freq < 3000) return 'orange';
                    return 'red';
                }
                // 功耗颜色
                function getPowerColor(power) {
                    power = parseFloat(power);
                    if (power < 20) return 'green';
                    if (power < 50) return 'orange';
                    return 'red';
                }

                const governor = value.cpu_governor || 'unknown';
                const power = value.cpu_power || '0';
                const freq = value.cpu_freq || '0';
                const minFreq = value.cpu_freq_min || '0';
                const maxFreq = value.cpu_freq_max || '0';

                return `模式: <span style="color:${getGovernorColor(governor)};font-weight:bold;">${governor}</span> | 
                        功耗: <span style="color:${getPowerColor(power)};font-weight:bold;">${power} W</span> | 
                        频率: <span style="color:${getFreqColor(freq)};font-weight:bold;">${freq} MHz</span> (最小: ${minFreq} MHz | 最大: ${maxFreq} MHz)`;
            }
        },
        {
            itemId: 'hw_temperature',
            colspan: 2,
            printBar: false,
            title: gettext('温度 & 风扇'),
            textField: 'hwmonitor',
            renderer: function(value) {
                function getTempColor(temp) {
                    temp = parseFloat(temp);
                    if (temp < 60) return 'green';
                    if (temp < 80) return 'orange';
                    return 'red';
                }

                let sensors = value.sensors || '';
                let output = [];
                
                // CPU 温度
                const cpuTemp = sensors.match(/Core\s+\d+:\s*\+([\d\.]+)°C/) || sensors.match(/Package id \d+:\s*\+([\d\.]+)°C/);
                if (cpuTemp) {
                    output.push(`CPU: <span style="color:${getTempColor(cpuTemp[1])};font-weight:bold;">${cpuTemp[1]}°C</span>`);
                }
                
                // 风扇转速
                const fanRpm = sensors.match(/fan\d+:\s*([\d\.]+) RPM/);
                if (fanRpm) {
                    output.push(`风扇: <span style="font-weight:bold;">${fanRpm[1]} RPM</span>`);
                }
                
                // 主板温度
                const boardTemp = sensors.match(/acpitz:\s*\+([\d\.]+)°C/);
                if (boardTemp) {
                    output.push(`主板: <span style="color:${getTempColor(boardTemp[1])};font-weight:bold;">${boardTemp[1]}°C</span>`);
                }

                return output.join(' | ') || '未检测到温度数据';
            }
        },
        {
            itemId: 'hw_disks',
            colspan: 2,
            printBar: false,
            title: gettext('硬盘信息'),
            textField: 'hwmonitor',
            renderer: function(value) {
                let output = [];
                
                // 处理 NVME 硬盘
                for (let key in value) {
                    if (key.startsWith('nvme')) {
                        try {
                            const data = JSON.parse(value[key]);
                            if (data.error) continue;
                            
                            const model = data.model_name || '未知NVME';
                            const temp = data.temperature?.current || '未知';
                            const health = data.nvme_smart_health_information_log?.percentage_used || '0';
                            
                            output.push(`${model}: 温度 ${temp}°C | 健康度 ${100 - health}%`);
                        } catch (e) {
                            continue;
                        }
                    }
                    
                    // 处理 SATA 硬盘
                    if (key.startsWith('sd')) {
                        try {
                            const data = JSON.parse(value[key]);
                            if (data.error) continue;
                            if (data.standby) {
                                output.push(`硬盘 ${key}: 休眠中`);
                                continue;
                            }
                            
                            const model = data.model_name || '未知SATA';
                            const temp = data.temperature?.current || '未知';
                            
                            output.push(`${model}: 温度 ${temp}°C`);
                        } catch (e) {
                            continue;
                        }
                    }
                }

                return output.join('<br>') || '未检测到硬盘数据';
            }
        },
EOF

# 插入到正确位置 (不干扰图表逻辑)
if grep -q 'pveversion' "$PVE_MANAGER_JS"; then
    # 找到 pveversion 项的下一个 }, 插入新内容
    ln=$(sed -n '/pveversion/,+10{/},/{=;q}}' "$PVE_MANAGER_JS")
    if [[ "$ln" =~ ^[0-9]+$ ]]; then
        sed -i "${ln}r /tmp/pve_hw_frontend.tmp" "$PVE_MANAGER_JS"
        echo -e "${GREEN}✅ pvemanagerlib.js 修改完成${NC}"
    else
        echo -e "${RED}⛔ 找不到插入位置!${NC}"
        exit 1
    fi
else
    echo -e "${RED}⛔ pvemanagerlib.js 锚点未找到!${NC}"
    exit 1
fi

rm -f /tmp/pve_hw_frontend.tmp

# -------------------- 调整页面高度 (适度调整，不影响图表) --------------------
echo -e "\n${BLUE}🎚️ 调整页面高度...${NC}"
# 只适度增加高度，避免破坏图表布局
sed -i -E "/Ext.define\('PVE.node.StatusView'/,/height:/{s/height: *[0-9]+,/height: 500,/}" "$PVE_MANAGER_JS"
sed -i -E "/widget.pveNodeStatus/,/height:/{s/height: *[0-9]+,/height: 500,/}" "$PVE_MANAGER_JS"
sed -i -E "/nodeStatus:\s*nodeStatus/,/minHeight:/{s/minHeight: *[0-9]+,/minHeight: 500,/}" "$PVE_MANAGER_JS"

# -------------------- 移除订阅弹窗 --------------------
echo -e "\n${BLUE}🚫 移除订阅弹窗...${NC}"
sed -i '/\/nodes\/localhost\/subscription/,+10{
    /res === null/{
        N
        s/(.*)/(false)/
        a //modbyshowtempfreq (disabled subscription popup)
    }
}' "$PROXMOX_LIB_JS"

# -------------------- 重启服务 --------------------
echo -e "\n${BLUE}🔁 重启 PVE 服务...${NC}"
systemctl restart pveproxy.service
systemctl restart pvedaemon.service

# -------------------- 完成 --------------------
echo -e "\n${GREEN}✅ 所有修改完成!${NC}"
echo -e "${YELLOW}💡 请按 Ctrl+F5 强制刷新浏览器缓存以生效${NC}"
echo -e "${YELLOW}💡 如果图表仍不显示，请清除浏览器缓存或使用无痕模式测试${NC}"