#!/usr/bin/env bash

# 合并后的脚本
# version: 2026.1.3

# 控制变量
sNVMEInfo=true  # 是否显示 NVMe 硬盘信息
sODisksInfo=true  # 是否显示 SATA 硬盘信息
debugMode=false  # 调试模式

# 脚本路径
sdir=$(cd "$(dirname "${BASH_SOURCE[0]}")"; pwd)
cd "$sdir"

# 获取 PVE 版本
pvever=$(pveversion | awk -F"/" '{print $2}')
echo "当前 PVE 版本: $pvever"

# 检查依赖
if ! command -v sensors > /dev/null; then
    echo "需要安装 lm-sensors 和 linux-cpupower"
    apt update && apt install -y lm-sensors linux-cpupower || {
        echo "依赖安装失败，请手动安装后重试。"
        exit 1
    }
fi

# 备份文件
backup_file() {
    local file=$1
    [ -e "$file" ] && cp "$file" "$file.$pvever.bak"
}

nodes="/usr/share/perl5/PVE/API2/Nodes.pm"
pvemanagerlib="/usr/share/pve-manager/js/pvemanagerlib.js"
backup_file "$nodes"
backup_file "$pvemanagerlib"

# 修改 Nodes.pm
if $sNVMEInfo || $sODisksInfo; then
    echo "修改 $nodes 文件..."
    cat >> "$nodes" << 'EOF'
    # 添加硬盘信息
    if $sNVMEInfo; then
        for nvme in $(ls /dev/nvme[0-9] 2> /dev/null); do
            $res->{nvme_info} = `smartctl $nvme -a -j`;
        done
    fi

    if $sODisksInfo; then
        for sd in $(ls /dev/sd[a-z] 2> /dev/null); do
            $res->{sata_info} = `smartctl $sd -a -j`;
        done
    fi
EOF
fi

# 修改 pvemanagerlib.js
if $sNVMEInfo || $sODisksInfo; then
    echo "修改 $pvemanagerlib 文件..."
    cat >> "$pvemanagerlib" << 'EOF'
    // 添加硬盘信息到前端页面
    {
        itemId: 'nvme_info',
        title: 'NVMe 硬盘信息',
        textField: 'nvme_info',
        renderer: function(value) {
            return value || '无 NVMe 硬盘信息';
        }
    },
    {
        itemId: 'sata_info',
        title: 'SATA 硬盘信息',
        textField: 'sata_info',
        renderer: function(value) {
            return value || '无 SATA 硬盘信息';
        }
    }
EOF
fi

# 重启服务
echo "重启 pveproxy 服务..."
systemctl restart pveproxy

echo "脚本执行完成，请刷新浏览器缓存 (Ctrl + F5)。"