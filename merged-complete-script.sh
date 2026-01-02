#!/usr/bin/env bash

# 合并后的完整脚本
# version: 2026.1.3

# 添加硬盘信息的控制变量
sNVMEInfo=true
sODisksInfo=true
# debug 模式
debugMode=false

# 脚本路径
sdir=$(cd "$(dirname "${BASH_SOURCE[0]}")"; pwd)
cd "$sdir"

# 获取脚本名称
sname=$(basename "${BASH_SOURCE[0]}")
sap=$sdir/$sname
echo "脚本路径：$sap"

# 获取 PVE 版本
pvever=$(pveversion | awk -F"/" '{print $2}')
echo "你的 PVE 版本号：$pvever"

# 定义需要修改的文件
nodes="/usr/share/perl5/PVE/API2/Nodes.pm"
pvemanagerlib="/usr/share/pve-manager/js/pvemanagerlib.js"
plibjs="/usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js"

# 备份函数
backup_file() {
    local file=$1
    [ -e "$file" ] && cp "$file" "$file.$pvever.bak"
}

# 备份文件
backup_file "$nodes"
backup_file "$pvemanagerlib"
backup_file "$plibjs"

# 检查依赖
if ! command -v sensors > /dev/null; then
    echo "需要安装 lm-sensors 和 linux-cpupower"
    apt update && apt install -y lm-sensors linux-cpupower || {
        echo "依赖安装失败，请手动安装后重试。"
        exit 1
    }
fi

# 配置传感器模块
sensors-detect --auto > /tmp/sensors
drivers=$(sed -n '/Chip drivers/,/\#----cut here/p' /tmp/sensors | sed '/Chip /d;/cut/d')
if [ -n "$drivers" ]; then
    for drv in $drivers; do
        modprobe "$drv"
        if ! grep -qx "$drv" /etc/modules; then
            echo "$drv" >> /etc/modules
        fi
    done
    if [[ -e /etc/init.d/kmod ]]; then
        /etc/init.d/kmod start &>/dev/null
    fi
fi
rm -f /tmp/sensors

# 修改 Nodes.pm
if ! grep -q 'modbyshowtempfreq' "$nodes"; then
    cat >> "$nodes" << 'EOF'
    # modbyshowtempfreq
    $res->{thermalstate} = `sensors -A`;
    $res->{cpuFreq} = `
        goverf=/sys/devices/system/cpu/cpufreq/policy0/scaling_governor
        maxf=/sys/devices/system/cpu/cpufreq/policy0/cpuinfo_max_freq
        minf=/sys/devices/system/cpu/cpufreq/policy0/cpuinfo_min_freq
        cat /proc/cpuinfo | grep -i  "cpu mhz"
        echo -n 'gov:'
        [ -f $goverf ] && cat $goverf || echo none
        echo -n 'min:'
        [ -f $minf ] && cat $minf || echo none
        echo -n 'max:'
        [ -f $maxf ] && cat $maxf || echo none
        echo -n 'pkgwatt:'
        [ -e /usr/sbin/turbostat ] && turbostat --quiet --cpu package --show "PkgWatt" -S sleep 0.25 2>&1 | tail -n1
    `;
EOF
fi

# 修改 pvemanagerlib.js
if ! grep -q 'modbyshowtempfreq' "$pvemanagerlib"; then
    cat >> "$pvemanagerlib" << 'EOF'
    // modbyshowtempfreq
    {
        itemId: 'thermal',
        colspan: 2,
        printBar: false,
        title: gettext('温度(°C)'),
        textField: 'thermalstate',
        renderer:function(value){
            let b = value.trim().split(/\s+(?=^\w+-)/m).sort();
            let c = b.map(function (v){
                let name = v.match(/^[^-]+/)[0].toUpperCase();
                let temp = v.match(/(?<=:\s+)[+-][\d.]+(?=.?°C)/g);
                if ( temp ) {
                    temp = temp.map(v => Number(v).toFixed(0));
                    if (/coretemp/i.test(name)) {
                        name = 'CPU';
                        temp = temp[0] + ( temp.length > 1 ? ' ( ' +   temp.slice(1).join(' | ') + ' )' : '');
                    } else {
                        temp = temp[0];
                    }
                    return name + ': ' + temp;
                } else {
                    return 'null';
                }
            });
            c=c.filter( v => ! /^null$/.test(v) );
            let cpuIdx = c.findIndex(v => /CPU/i.test(v) );
            if (cpuIdx > 0) {
                c.unshift(c.splice(cpuIdx, 1)[0]);
            }
            return c.join(' | ');
        }
    },
EOF
fi

# 重启服务
echo "重启 pveproxy 服务..."
systemctl restart pveproxy

echo "脚本执行完成，请刷新浏览器缓存 (Ctrl + F5)。"