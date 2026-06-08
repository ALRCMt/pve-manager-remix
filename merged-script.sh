#!/usr/bin/env bash

# 合并后的脚本，确保 pve-manager-status.sh 先执行，showtempcpufreq.sh 后执行
# version: 26.6.8

# --------------------
# pve-manager-status.sh 的内容
# --------------------

#!/bin/bash
# pve-manager-status.sh
# Last Modified: 2025-10-28

echo -e "\n \033[1;33;41mPVE-Manager-Status v26.6.8 by ALRCMt\033[0m"

echo -e "为 ProxmoxVE 节点概要页面添加扩展硬件监控信息"
echo -e "OpenSource on GitHub (https://github.com/ALRCMt/pve-manager-remix)\n"
echo -e "脚本大部分内容来自，我只是粘合作用
https://github.com/MiKing233/PVE-Manager-Status 
https://github.com/a904055262/PVE-manager-status 
感谢两位大佬"
# 先决条件执行判断
# 执行用户判断, 必须为 root 用户执行
if [ "$(id -u)" -ne 0 ]; then
    echo -e " 请以 root 身份运行此脚本!"
    echo && exit 1
fi

# 执行环境判断, 必须为 Debian 发行版且存在 ProxmoxVE 环境
if ! command -v pveversion &> /dev/null; then
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        if [[ "$ID" != "debian" && "$ID_LIKE" != *"debian"* ]]; then
            echo -e " 检测到当前系统非 Debian 发行版, 停止执行!"
            echo && exit 1
        fi
    fi
    echo -e " 未检测到 ProxmoxVE 环境, 停止执行!"
    echo && exit 1
fi

read -p "确认执行吗? [y/N]:" para

# 脚本执行前确认
[[ "$para" =~ ^[Yy]$ ]] || { [[ "$para" =~ ^[Nn]$ ]] && echo -e "\n 操作取消, 未执行任何操作!" && exit 0; echo -e "\n 无效输入, 未执行任何操作!"; exit 1; }

nodes="/usr/share/perl5/PVE/API2/Nodes.pm"
pvemanagerlib="/usr/share/pve-manager/js/pvemanagerlib.js"
pvever=$(pveversion | awk -F"/" '{print $2}')

echo -e "\n 当前 Proxmox VE 版本: $pvever"



####################   备份步骤   ####################

echo -e "\n 修改开始前备份原文件:"

delete_old_backups() {
    local pattern="$1"
    local description="$2"

    shopt -s nullglob
    local files=($pattern)
    shopt -u nullglob

    if [ ${#files[@]} -gt 0 ]; then
        for file in "${files[@]}"; do
            echo "旧备份清理: $file "
        done
        rm -f "${files[@]}"
    else
        echo "没有发现任何旧备份文件! "
    fi
}
echo -e "清理旧的备份文件..."
delete_old_backups "${nodes}.*.bak" "nodes"
delete_old_backups "${pvemanagerlib}.*.bak" "pvemanagerlib"

echo -e "备份当前将要被修改的文件..."
cp "$nodes" "${nodes}.${pvever}.bak"
echo "新备份生成: ${nodes}.${pvever}.bak "
cp "$pvemanagerlib" "${pvemanagerlib}.${pvever}.bak"
echo "新备份生成: ${pvemanagerlib}.${pvever}.bak "



####################   依赖检查 & 环境准备   ####################

# 避免重复修改, 重装 pve-manager
echo -e "\n 避免重复修改, 重新安装 pve-manager..."
apt-get install --reinstall -y pve-manager

# 软件包依赖
echo -e "\n 检查依赖软件包安装情况..."
packages=(sudo sysstat lm-sensors smartmontools linux-cpupower)
missing=()

# 检查依赖状态
installed_list=$(apt list --installed 2>/dev/null)
for pkg in "${packages[@]}"; do
    if echo "$installed_list" | grep -q "^$pkg/"; then
        echo "$pkg: 已安装"
    else
        echo "$pkg: 未安装"
        missing+=("$pkg")
    fi
done

# 安装缺失的包
if [ ${#missing[@]} -ne 0 ]; then
    echo -e "\n 检查到软件包缺失: ${missing[*]} 开始安装..."
    if ! (apt-get update && apt-get install -y "${missing[@]}"); then
        echo -e "\n 依赖软件包安装失败! 请检查你的 apt 源配置或网络连接"
        echo && exit 1
    fi
    echo -e " 依赖软件包已成功安装!"
else
    echo -e "所有依赖软件包均已安装!"
fi

# 配置传感器模块
echo -e "\n 开始配置传感器模块..."
sensors-detect --auto > /tmp/sensors

drivers=$(sed -n '/Chip drivers/,/\#----cut here/p' /tmp/sensors | sed '/Chip /d;/cut/d')

if [ -n "$drivers" ]; then
    echo "发现传感器模块, 正在配置以便开机自动加载"
    for drv in $drivers; do
        modprobe "$drv"
        if grep -qx "$drv" /etc/modules; then
            echo "模块 $drv 已存在于 /etc/modules "
        else
            echo "$drv" >> /etc/modules
            echo "模块 $drv 已添加至 /etc/modules "
        fi
    done
    if [[ -e /etc/init.d/kmod ]]; then
        echo "正在应用模块配置使其立即生效..."
        /etc/init.d/kmod start &>/dev/null
        echo "模块配置已生效 "
    else
        echo "未找到 /etc/init.d/kmod 跳过此步骤 "
    fi
    echo "传感器模块已配置完成!"
elif grep -q "No modules to load, skipping modules configuration" /tmp/sensors; then
    echo "未找到需要手动加载的模块, 跳过配置步骤 (可能已由内核自动加载) "
elif grep -q "Sorry, no sensors were detected" /tmp/sensors; then
    echo "未检测到任何传感器, 跳过配置步骤 (当前环境可能为虚拟机) "
else
    echo "发生预期外的错误, 跳过配置步骤! 你的设备可能不支持或内核未包含相关模块 "
fi

rm -f /tmp/sensors

# 配置必要的执行权限 (替代危险的 chmod +s)
echo -e "\n 配置必要的执行权限..."
echo -e "允许 www-data 用户以 sudo 权限执行特定监控命令"
SUDOERS_FILE="/etc/sudoers.d/pve-manager-status"
# 首先移除可能被添加的 SUID 权限设置, 以防曾经被其它监控脚本添加
binaries=(/usr/sbin/nvme /usr/bin/iostat /usr/bin/sensors /usr/bin/cpupower /usr/sbin/smartctl /usr/sbin/turbostat)
for bin in "${binaries[@]}"; do
    if [[ -e $bin && -u $bin ]]; then
        chmod -s "$bin" && echo "检测到不安全的 SUID 权限已移除: $bin "
    fi
done

# 定义需要 sudo 权限执行命令的绝对路径
IOSTAT_PATH=$(command -v iostat)
SENSORS_PATH=$(command -v sensors)
SMARTCTL_PATH=$(command -v smartctl)
TURBOSTAT_PATH=$(command -v turbostat)

# 配置 sudoers 规则内容
echo -e "正在配置 sudoers 规则内容并进行语法检查..."
read -r -d '' SUDOERS_CONTENT << EOM
# Allow www-data user (PVE Web GUI) to run specific hardware monitoring commands
# This file is managed by pve-manager-status.sh (https://github.com/MiKing233/PVE-Manager-Status)

www-data ALL=(root) NOPASSWD: ${SENSORS_PATH}
www-data ALL=(root) NOPASSWD: ${SMARTCTL_PATH} -a /dev/*
www-data ALL=(root) NOPASSWD: ${IOSTAT_PATH} -d -x -k 1 1
www-data ALL=(root) NOPASSWD: ${TURBOSTAT_PATH} -S -q -s PkgWatt -i 0.1 -n 1 -c package
EOM

# 使用 visudo 在最终添加前对 sudoers 规则执行语法检查
TMP_SUDOERS=$(mktemp)
echo "${SUDOERS_CONTENT}" > "${TMP_SUDOERS}"

if visudo -c -f "${TMP_SUDOERS}" &> /dev/null; then
    echo "sudoers 规则语法检查通过 "
    mv "${TMP_SUDOERS}" "${SUDOERS_FILE}"
    chown root:root "${SUDOERS_FILE}"
    chmod 0440 "${SUDOERS_FILE}"
    echo "已成功配置 sudo 规则于: ${SUDOERS_FILE} "
else
    echo " sudoers 规则语法错误, 操作终止!"
    echo -e "\n--- DEBUG INFO START ---"
    echo "生成的 sudoers 规则内容如下:"
    echo "--------------------------------------------------"
    cat "${TMP_SUDOERS}"
    echo "--------------------------------------------------"
    echo
    echo "visudo 语法检查的详细错误信息:"
    echo "--------------------------------------------------"
    visudo -c -f "${TMP_SUDOERS}"
    echo "--------------------------------------------------"
    echo -e "\n--- DEBUG INFO END ---"
    rm -f "${TMP_SUDOERS}"
    echo && exit 1
fi

# 确保 msr 模块被加载并设为开机自启, 为 turbostat 提供支持
modprobe msr && echo msr > /etc/modules-load.d/turbostat-msr.conf



####################   概要页面监控功能实现   ####################

echo -e "\n 添加概要页面硬件监控信息..."

# 修改 node.pm 文件前置步骤
tmpf1=$(mktemp /tmp/pve-manager-status.XXXXXX) || exit 1
cat > "$tmpf1" << 'EOF'

        my $cpumodes = `cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor`;
        my $cpupowers = `sudo turbostat -S -q -s PkgWatt -i 0.1 -n 1 -c package | grep -v PkgWatt`;
        $res->{cpupower} = $cpumodes . $cpupowers;

        my $cpufreqs = `lscpu | grep MHz`;
        my $threadfreqs = `cat /proc/cpuinfo | grep -i "cpu MHz"`;
        $res->{cpufreq} = $cpufreqs . $threadfreqs;

        $res->{sensors} = `sudo sensors`;
EOF

# 在实际修改前检查锚点文本是否存在, 若不存在则报错退出停止修改
if ! grep -q 'PVE::pvecfg::version_text' "$nodes"; then
    echo " 在 $nodes 中未找到锚点, 操作终止!"
    rm -f "$tmpf1"
    echo -e " 锚点'PVE::pvecfg::version_text', 文件可能已更新或与当前版本不兼容\n" && exit 1
fi

# 应用更改
sed -i '/PVE::pvecfg::version_text/ r '"$tmpf1"'' "$nodes"

# 验证修改是否成功
if grep -q 'cpupower' "$nodes"; then
    echo "已完成修改: $nodes "
else
    echo " 检查对 $nodes 添加的内容未生效!"
    rm -f "$tmpf1"
    echo -e " 请检查文件权限或手动检查文件内容\n" && exit 1
fi

rm -f "$tmpf1"



# 修改 pvemanagerlib.js 文件前置步骤
tmpf2=$(mktemp /tmp/pve-manager-status.XXXXXX) || exit 1
cat > "$tmpf2" << 'EOF'
        {
            itemId: 'cpupower',
            colspan: 2,
            printBar: false,
            title: gettext('CPU能耗'),
            textField: 'cpupower',
            renderer:function(value){
                function colorizeCpuMode(mode) {
                    if (mode === 'powersave') return `<span style="color:green; font-weight:bold;">${mode}</span>`;
                    if (mode === 'performance') return `<span style="color:red; font-weight:bold;">${mode}</span>`;
                    return `<span style="color:orange; font-weight:bold;">${mode}</span>`;
                }
                function colorizeCpuPower(power) {
                    const powerNum = parseFloat(power);
                    if (powerNum < 20) return `<span style="color:green; font-weight:bold;">${power} W</span>`;
                    if (powerNum < 50) return `<span style="color:orange; font-weight:bold;">${power} W</span>`;
                    return `<span style="color:red; font-weight:bold;">${power} W</span>`;
                }
                const lines = value.split('\n');
                const w0 = lines[0] ? lines[0].split(' ')[0] : 'N/A';
                const w1 = lines[1] ? lines[1].split(' ')[0] : 'N/A';
                return `CPU电源模式: ${colorizeCpuMode(w0)} | CPU功耗: ${colorizeCpuPower(w1)}`
            }
        },
        {
            itemId: 'cpufreq',
            colspan: 2,
            printBar: false,
            title: gettext('CPU频率'),
            textField: 'cpufreq',
            renderer:function(value){
                function colorizeCpuFreq(freq) {
                    const freqNum = parseFloat(freq);
                    if (freqNum < 1500) return `<span style="color:green; font-weight:bold;">${freq} MHz</span>`;
                    if (freqNum < 3000) return `<span style="color:orange; font-weight:bold;">${freq} MHz</span>`;
                    return `<span style="color:red; font-weight:bold;">${freq} MHz</span>`;
                }
                const match0 = value.match(/cpu MHz.*?([\d]+)/);
                const match1 = value.match(/CPU min MHz.*?([\d]+)/);
                const match2 = value.match(/CPU max MHz.*?([\d]+)/);
                const f0 = match0 ? match0[1] : 'N/A';
                const f1 = match1 ? match1[1] : 'N/A';
                const f2 = match2 ? match2[1] : 'N/A';
                return `CPU实时: ${colorizeCpuFreq(f0)} | 最小: ${f1} MHz | 最大: ${f2} MHz `
            }
        },
        {
            itemId: 'sensors',
            colspan: 2,
            printBar: false,
            title: gettext('传感器'),
            textField: 'sensors',
            renderer: function(value) {
                function colorizeCpuTemp(temp) {
                    const tempNum = parseFloat(temp);
                    if (tempNum < 60) return `<span style="color:green; font-weight:bold;">${temp}°C</span>`;
                    if (tempNum < 80) return `<span style="color:orange; font-weight:bold;">${temp}°C</span>`;
                    return `<span style="color:red; font-weight:bold;">${temp}°C</span>`;
                }
                function colorizeGpuTemp(temp) {
                    const tempNum = parseFloat(temp);
                    if (tempNum < 60) return `<span style="color:green; font-weight:bold;">${temp}°C</span>`;
                    if (tempNum < 80) return `<span style="color:orange; font-weight:bold;">${temp}°C</span>`;
                    return `<span style="color:red; font-weight:bold;">${temp}°C</span>`;
                }
                function colorizeAcpiTemp(temp) {
                    const tempNum = parseFloat(temp);
                    if (tempNum < 60) return `<span style="color:green; font-weight:bold;">${temp}°C</span>`;
                    if (tempNum < 80) return `<span style="color:orange; font-weight:bold;">${temp}°C</span>`;
                    return `<span style="color:red; font-weight:bold;">${temp}°C</span>`;
                }
                function colorizeFanRpm(rpm) {
                    const rpmNum = parseFloat(rpm);
                    if (rpmNum < 1500) return `<span style="color:green; font-weight:bold;">${rpm}转/分钟</span>`;
                    if (rpmNum < 3000) return `<span style="color:orange; font-weight:bold;">${rpm}转/分钟</span>`;
                    return `<span style="color:red; font-weight:bold;">${rpm}转/分钟</span>`;
                }
                value = value.replace(/Â/g, '');
                let data = [];
                let cpus = value.matchAll(/^(?:coretemp-isa|k10temp-pci)-(\w{4})$\n.*?\n((?:Package|Core|Tctl)[\s\S]*?^\n)+/gm);
                for (const cpu of cpus) {
                    let cpuNumber = parseInt(cpu[1], 10);
                    data[cpuNumber] = {
                        packages: [],
                        cores: []
                    };

                    let packages = cpu[2].matchAll(/^(?:Package id \d+|Tctl):\s*\+([^°C ]+).*$/gm);
                    for (const package of packages) {
                        data[cpuNumber]['packages'].push(package[1]);
                    }
                    let cores = cpu[2].matchAll(/^Core (\d+):\s*\+([^°C ]+).*$/gm);
                    for (const core of cores) {
                        var corecombi = `核心 ${core[1]}: ${colorizeCpuTemp(core[2])}`
                        data[cpuNumber]['cores'].push(corecombi);
                    }
                }

                let output = '';
                for (const [i, cpu] of data.entries()) {
                    if (cpu.packages.length > 0) {
                        for (const packageTemp of cpu.packages) {
                            output += `CPU ${i}: ${colorizeCpuTemp(packageTemp)} | `;
                        }
                    }

                    let gpus = value.matchAll(/^amdgpu-pci-(\w*)$\n((?!edge:)[ \S]*?\n)*((?:edge)[\s\S]*?^\n)+/gm);
                    for (const gpu of gpus) {
                        let gpuNumber = 0;
                        data[gpuNumber] = {
                            edges: []
                        };

                        let edges = gpu[3].matchAll(/^edge:\s*\+([^°C ]+).*$/gm);
                        for (const edge of edges) {
                            data[gpuNumber]['edges'].push(edge[1]);
                        }

                        for (const [k, gpu] of data.entries()) {
                            if (gpu.edges.length > 0) {
                                output += '核显: ';
                                for (const edgeTemp of gpu.edges) {
                                    output += `${colorizeGpuTemp(edgeTemp)}, `;
                                }
                                output = output.slice(0, -2);
                                output += ' | ';
                            } else {
                                output = output.slice(0, -2);
                            }
                        }
                    }

                    let acpitzs = value.matchAll(/^acpitz-acpi-(\d*)$\n.*?\n((?:temp)[\s\S]*?^\n)+/gm);
                    for (const acpitz of acpitzs) {
                        let acpitzNumber = parseInt(acpitz[1], 10);
                        data[acpitzNumber] = {
                            acpisensors: []
                        };

                        let acpisensors = acpitz[2].matchAll(/^temp\d+:\s*\+([^°C ]+).*$/gm);
                        for (const acpisensor of acpisensors) {
                            data[acpitzNumber]['acpisensors'].push(acpisensor[1]);
                        }

                        for (const [k, acpitz] of data.entries()) {
                            if (acpitz.acpisensors.length > 0) {
                                output += '主板: ';
                                for (const acpiTemp of acpitz.acpisensors) {
                                    output += `${colorizeAcpiTemp(acpiTemp)}, `;
                                }
                                output = output.slice(0, -2);
                                output += ' | ';
                            } else {
                                output = output.slice(0, -2);
                            }
                        }
                    }

                    let FunStates = value.matchAll(/^(?:[a-zA-z]{2,3}\d{4}|dell_smm)-isa-(\w{4})$\n((?![ \S]+: *\d+ +RPM)[ \S]*?\n)*((?:[ \S]+: *\d+ RPM)[\s\S]*?^\n)+/gm);
                    for (const FunState of FunStates) {
                        let FanNumber = 0;
                        data[FanNumber] = {
                            rotationals: [],
                            cpufans: [],
                            motherboardfans: [],
                            pumpfans: [],
                            systemfans: []
                        };

                        let rotationals = FunState[3].match(/^([ \S]+: *[0-9]\d* +RPM)[ \S]*?$/gm);
                        for (const rotational of rotationals) {
                            if (rotational.toLowerCase().indexOf("pump") !== -1 || rotational.toLowerCase().indexOf("opt") !== -1){
                                let pumpfans = rotational.matchAll(/^[ \S]+: *([1-9]\d*) +RPM[ \S]*?$/gm);
                                for (const pumpfan of pumpfans) {
                                    data[FanNumber]['pumpfans'].push(pumpfan[1]);
                                }
                            } else if (rotational.toLowerCase().indexOf("cpu") !== -1 || rotational.toLowerCase().indexOf("processor") !== -1){
                                let cpufans = rotational.matchAll(/^[ \S]+: *([1-9]\d*) +RPM[ \S]*?$/gm);
                                for (const cpufan of cpufans) {
                                    data[FanNumber]['cpufans'].push(cpufan[1]);
                                }
                            } else if (rotational.toLowerCase().indexOf("motherboard") !== -1){
                                let motherboardfans = rotational.matchAll(/^[ \S]+: *([1-9]\d*) +RPM[ \S]*?$/gm);
                                for (const motherboardfan of motherboardfans) {
                                    data[FanNumber]['motherboardfans'].push(motherboardfan[1]);
                                }
                            }  else {
                                let systemfans = rotational.matchAll(/^[ \S]+: *([1-9]\d*) +RPM[ \S]*?$/gm);
                                for (const systemfan of systemfans) {
                                    data[FanNumber]['systemfans'].push(systemfan[1]);
                                }
                            }
                        }

                        for (const [j, FunState] of data.entries()) {
                            if (FunState.cpufans.length > 0 || FunState.motherboardfans.length > 0 || FunState.pumpfans.length > 0 || FunState.systemfans.length > 0) {
                                output += '风扇: ';
                                if (FunState.cpufans.length > 0) {
                                    output += 'CPU-';
                                    for (const cpufan_value of FunState.cpufans) {
                                        output += `${colorizeFanRpm(cpufan_value)}, `;
                                    }
                                }

                                if (FunState.motherboardfans.length > 0) {
                                    output += '主板-';
                                    for (const motherboardfan_value of FunState.motherboardfans) {
                                        output += `${colorizeFanRpm(motherboardfan_value)}, `;
                                    }
                                }

                                if (FunState.pumpfans.length > 0) {
                                    output += '水冷-';
                                    for (const pumpfan_value of FunState.pumpfans) {
                                        output += `${colorizeFanRpm(pumpfan_value)}, `;
                                    }
                                }

                                if (FunState.systemfans.length > 0) {
                                    if (FunState.cpufans.length > 0 || FunState.pumpfans.length > 0) {
                                        output += '系统-';
                                    }
                                    for (const systemfan_value of FunState.systemfans) {
                                        output += `${colorizeFanRpm(systemfan_value)}, `;
                                    }
                                }
                                output = output.slice(0, -2);
                                output += ' | ';
                            } else if (FunState.cpufans.length == 0 && FunState.pumpfans.length == 0 && FunState.systemfans.length == 0) {
                                output += ' 风扇: 停转';
                                output += ' | ';
                            } else {
                                output = output.slice(0, -2);
                            }
                        }
                    }
                    output = output.slice(0, -2);

                    if (cpu.cores.length > 1) {
                        output += '\n';
                        for (j = 1;j < cpu.cores.length;) {
                            for (const coreTemp of cpu.cores) {
                                output += `${coreTemp} | `;
                                j++;
                                if ((j-1) % 4 == 0){
                                    output = output.slice(0, -2);
                                    output += '\n';
                                }
                            }
                        }
                        output = output.slice(0, -2);
                    }
                    output += '\n';
                }

                output = output.slice(0, -2);
                return output.replace(/\n/g, '<br>');
            }
        },
        {
            itemId: 'corefreq',
            colspan: 2,
            printBar: false,
            title: gettext('核心频率'),
            textField: 'cpufreq',
            renderer: function(value) {
                function colorizeCpuFreq(freq) {
                    const freqNum = parseFloat(freq);
                    if (freqNum < 1500) return `<span style="color:green; font-weight:bold;">${freq} MHz</span>`;
                    if (freqNum < 3000) return `<span style="color:orange; font-weight:bold;">${freq} MHz</span>`;
                    return `<span style="color:red; font-weight:bold;">${freq} MHz</span>`;
                }
                const freqMatches = value.matchAll(/^cpu MHz\s*:\s*([\d\.]+)/gm);
                const frequencies = [];

                for (const match of freqMatches) {
                    const coreNum = frequencies.length + 1;
                    frequencies.push(`线程 ${coreNum}: ${colorizeCpuFreq(parseInt(match[1]))}`);
                }

                if (frequencies.length === 0) {
                    return '无法获取CPU频率信息';
                }

                const groupedFreqs = [];
                for (let i = 0; i < frequencies.length; i += 4) {
                    const group = frequencies.slice(i, i + 4);
                    groupedFreqs.push(group.join(' | '));
                }

                return groupedFreqs.join('<br>');
            }
        },
EOF

# 计算插入行号
ln=$(sed -n '/pveversion/,+10{/},/{=;q}}' $pvemanagerlib)

# 在实际修改前检查行号是否有效, 若无效则报错退出停止修改
if ! [[ "$ln" =~ ^[0-9]+$ ]]; then
    echo " 在 $pvemanagerlib 中计算插入位置失败, 操作终止!"
    rm -f "$tmpf2"
    echo -e " 锚点'pveversion', 文件可能已更新或与当前版本不兼容\n" && exit 1
fi

# 应用更改
sed -i "${ln}r $tmpf2" "$pvemanagerlib"

# 验证修改是否成功
if grep -q "itemId: 'cpupower'" "$pvemanagerlib"; then
    echo "已完成修改: $pvemanagerlib "
else
    echo " 检查对 $pvemanagerlib 添加的内容未生效!"
    rm -f "$tmpf2"
    echo -e " 请检查文件权限或手动检查文件内容\n" && exit 1
fi

rm -f "$tmpf2"



####################   zh-CN 本地化   ####################

echo -e "\n 添加缺失的 zh-CN 翻译..."

pve_major_ver=$(echo "$pvever" | cut -d'.' -f1)

case "$pve_major_ver" in
    "8")
        # PVE 8.x: 为 Network traffic 图表添加中文 fieldTitles
        if ! grep -q "fields: \['netin', 'netout'\]" "$pvemanagerlib"; then
            echo -e " 未找到 Network traffic 的锚点, 操作终止!"
            echo -e " 锚点 \"fields: ['netin', 'netout']\", 文件可能已更新或与当前版本不兼容\n" && exit 1
        else
            if grep -q "fieldTitles: \[gettext('传入'), gettext('发送')\]" "$pvemanagerlib"; then
                echo -e "Network traffic 的中文翻译已存在, 跳过该步骤 "
            else
                sed -i "s/^\( *\)fields: \['netin', 'netout'\],/&\n\1fieldTitles: [gettext('传入'), gettext('发送')],/" "$pvemanagerlib"
                if grep -q "fieldTitles: \[gettext('传入'), gettext('发送')\]" "$pvemanagerlib"; then
                    echo -e "已添加 PVE 8.x 缺失的翻译: 网络流量 图表上的 (传入)和(发送)按钮 "
                else
                    echo -e " 检查对 Network traffic 部分的中文 fieldTitles 修改未生效!"
                    echo -e " 请检查文件权限或手动检查文件内容\n" && exit 1
                fi
            fi
        fi

        if ! grep -q "fields: \['diskread', 'diskwrite'\]" "$pvemanagerlib"; then
            echo -e " 未找到 Disk IO 的锚点, 操作终止!"
            echo -e " 锚点 \"fields: ['diskread', 'diskwrite']\", 文件可能已更新或与当前版本不兼容\n" && exit 1
        else
            if grep -q "fieldTitles: \[gettext('读取'), gettext('写入')\]" "$pvemanagerlib"; then
                echo -e "Disk IO 的中文翻译已存在, 跳过该步骤 "
            else
                sed -i "s/^\( *\)fields: \['diskread', 'diskwrite'\],/&\n\1fieldTitles: [gettext('读取'), gettext('写入')],/" "$pvemanagerlib"
                if grep -q "fieldTitles: \[gettext('读取'), gettext('写入')\]" "$pvemanagerlib"; then
                    echo -e "已添加 PVE 8.x 缺失的翻译: 磁盘IO 图表上的 (读取)和(写入)按钮 "
                else
                    echo -e " 检查对 Disk IO 部分的中文 fieldTitles 修改未生效!"
                    echo -e " 请检查文件权限或手动检查文件内容\n" && exit 1
                fi
            fi
        fi
        ;;
    "9")
        echo -e "正在检查并补全 PVE 9 缺失的中文翻译..."

        pve_i18n_CN="/usr/share/pve-i18n/pve-lang-zh_CN.js"

        PVE9_TRANSLATIONS=(
            '"1208454600":["平均值"]'
            '"1653956129":["最大值"]'
            '"871356310":["服务器负载"]'
            '"1299201244":["网络流量"]'
            '"755456338":["CPU 压力停滞"]'
            '"858045066":["IO 压力停滞"]'
            '"431218371":["内存压力停滞"]'
            '"1102487829":["内存使用率"]'
            '"517429357":["主机内存使用量"]'
            '"1075229421":["主机内存使用量"]'
        )

        if ! grep -q "^__proxmox_i18n_msgcat__ =" "$pve_i18n_CN"; then
            echo -e " 未找到翻译字典中的锚点 (__proxmox_i18n_msgcat__ =), 操作终止!"
            exit 1
        fi

        for item in "${PVE9_TRANSLATIONS[@]}"; do
            hash_id=$(echo "$item" | cut -d'"' -f2)
            zh_text=$(echo "$item" | cut -d'"' -f4)

            if grep -q "\"$hash_id\":" "$pve_i18n_CN"; then
                echo -e "已存在: [$hash_id] => $zh_text "
            else
                sed -i "/^__proxmox_i18n_msgcat__ =/ s/};$/,${item}\};/" "$pve_i18n_CN"
                if grep -q "\"$hash_id\":" "$pve_i18n_CN"; then
                    echo -e "已添加: [$hash_id] => $zh_text "
                else
                    echo -e "未生效: [$hash_id] => $zh_text "
                fi
            fi
        done
        ;;
    *)
        echo -e "\n 不支持的PVE版本($pvever), 跳过 zh-CN 本地化."
        ;;
esac



####################   调整页面高度   ####################

echo -e "\n 调整修改后的页面高度..."

# 基于模型: 每行内容 17px, 每个模块段落间额外 7px 间距
calculate_height_increase() {
    local total_lines=0
    local module_count=0

    # itemId:cpupower(CPU能耗): 固定1行
    total_lines=$((total_lines + 1))
    module_count=$((module_count + 1))

    # itemId:cpufreq(CPU频率): 固定1行
    total_lines=$((total_lines + 1))
    module_count=$((module_count + 1))

    # itemId:sensors(传感器): 主信息固定1行
    total_lines=$((total_lines + 1))
    module_count=$((module_count + 1))
    # 使用 sensors 命令输出根据核心数量计算额外行数
    local core_temp_count=$(sudo sensors 2>/dev/null | grep -c '^Core')
    if [ "$core_temp_count" -gt 1 ]; then
        local sensor_core_lines=$(((core_temp_count + 4 - 1) / 4))
        total_lines=$((total_lines + sensor_core_lines))
    fi

    # itemId:corefreq(核心频率): 无固定行
    module_count=$((module_count + 1))
    # 根据 /proc/cpuinfo 输出的线程数量计算额外行数
    local thread_count=$(grep -c ^processor /proc/cpuinfo)
    if [ "$thread_count" -gt 0 ]; then
        local core_freq_lines=$(((thread_count + 4 - 1) / 4))
        total_lines=$((total_lines + core_freq_lines))
    fi

    # 根据模型计算总高度增量: (行数 * 17px) + (模块数 * 7px)
    local height_increase=$((total_lines * 17 + module_count * 7))
    echo $height_increase
}

# 获取计算出的高度增量
height_increase=$(calculate_height_increase)

# 基于基础高度(350px)计算新高度
new_height=$((350 + height_increase))

# 使用 sed 命令定位并更新 PVE.node.StatusView 的 height 属性
sed -i -E "/Ext.define\('PVE.node.StatusView'/,/height:/{s/height: *[0-9]+,/height: $new_height,/}" "$pvemanagerlib"
echo "页面高度经计算模型已动态调整为 ${new_height}px "

ln=$(expr $(sed -n -e '/widget.pveDcGuests/=' $pvemanagerlib) + 10)
sed -i "${ln}a\ textAlign: 'right'," $pvemanagerlib
ln=$(expr $(sed -n -e '/widget.pveNodeStatus/=' $pvemanagerlib) + 10)
sed -i "${ln}a\ textAlign: 'right'," $pvemanagerlib



####################   修改全部完成后重启服务   ####################

# 将以下代码移至脚本末尾，确保所有逻辑执行完毕后再重启服务
# echo -e "\n 等待服务 pveproxy.service 重启..."
# timeout 10s systemctl restart pveproxy.service &> /dev/null
# restart_status=$?
# if [ $restart_status -ne 0 ]; then
#     if [ $restart_status -eq 124 ]; then
#         echo -e "\n 重启服务 pveproxy.service 超时 (timeout 10s)"
#     else
#         echo -e "\n 重启服务 pveproxy.service 失败 ($restart_status)"
#     fi
#     echo -e "\n 请检查服务状态信息以排查问题\n"
#     systemctl status pveproxy.service --no-pager
#     echo && exit 1
# fi

# echo "systemctl restart pveproxy" # showtempcpufreq.sh 部分的重启逻辑



# 在脚本末尾添加服务重启逻辑

####################   脚本末尾服务重启   ####################
# echo -e "\n 等待服务 pveproxy.service 重启..."
#timeout 10s systemctl restart pveproxy.service &> /dev/null
#restart_status=$?
#if [ $restart_status -ne 0 ]; then
#    if [ $restart_status -eq 124 ]; then
#        echo -e "\n 重启服务 pveproxy.service 超时 (timeout 10s)"
#    else
#        echo -e "\n 重启服务 pveproxy.service 失败 ($restart_status)"
#    fi
#    echo -e "\n 请检查服务状态信息以排查问题\n"
#    systemctl status pveproxy.service --no-pager
#    echo && exit 1
# fi

echo -e "\n 修改完成, 请使用 Ctrl + F5 刷新浏览器 Proxmox VE Web 管理页面缓存\n"


# --------------------
# showtempcpufreq.sh 的内容
# --------------------

#!/usr/bin/env bash

# version: 2023.9.5
# 添加硬盘信息的控制变量，如果你想不显示硬盘信息就设置为false
# NVME硬盘
sNVMEInfo=true
# 固态和机械硬盘
sODisksInfo=true
# debug，显示修改后的内容，用于调试
dmode=false

#脚本路径
sdir=$(cd "$(dirname "${BASH_SOURCE[0]}")"; pwd)
cd "$sdir"

sname=$(basename "${BASH_SOURCE[0]}")
sap=$sdir/$sname
echo 脚本路径："$sap"

#需要修改的文件
np=/usr/share/perl5/PVE/API2/Nodes.pm
pvejs=/usr/share/pve-manager/js/pvemanagerlib.js
plibjs=/usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js

if ! command -v sensors > /dev/null; then
	echo 你需要先安装 lm-sensors 和 linux-cpupower，脚本尝试给你自动安装
	if apt update ; apt install -y lm-sensors; then 
		echo lm-sensors 安装成功
		
		echo 尝试继续安装linux-cpupower获取功耗信息
		if apt install -y linux-cpupower;then
			echo linux-cpupower安装成功
		else
			echo -e "linux-cpupower安装失败，可能无法正常获取功耗信息，你可以使用\033[34mapt update ; apt install linux-cpupower && modprobe msr && echo msr > /etc/modules-load.d/turbostat-msr.conf && chmod +s /usr/sbin/turbostat && echo 成功！\033[0m 手动安装"
		fi
	else
		echo 脚本自动安装所需依赖失败
		echo -e "请使用蓝色命令：\033[34mapt update ; apt install -y lm-sensors linux-cpupower && chmod +s /usr/sbin/turbostat && echo 成功！ \033[0m 手动安装后重新运行本脚本"
		echo 脚本退出
		exit 1
	fi
fi


#获取版本号
pvever=$(pveversion | awk -F"/" '{print $2}')
echo "你的PVE版本号：$pvever"

restore() {
	[ -e $np.$pvever.bak ]     && mv $np.$pvever.bak $np
	[ -e $pvejs.$pvever.bak ]  && mv $pvejs.$pvever.bak $pvejs
	[ -e $plibjs.$pvever.bak ] && mv $plibjs.$pvever.bak $plibjs
}

fail() {
	echo "修改失败，可能不兼容你的pve版本：$pvever，开始还原"
	restore
	echo 还原完成
	exit 1
}

#还原修改
case $1 in 
	restore)
		restore
		echo 已还原修改
		
		if [ "$2" != 'remod' ];then 
			echo -e "请刷新浏览器缓存：\033[31mShift+F5\033[0m"
			systemctl restart pveproxy
		else 
			echo -----
		fi
		
		exit 0
	;;
	remod)
		echo 强制重新修改
		echo -----------
		"$sap" restore remod > /dev/null 
		"$sap"
		exit 0
	;;
esac

#检测是否已经修改过
[ $(grep 'modbyshowtempfreq' $np $pvejs $plibjs | wc -l) -eq 3 ]  && {
	echo -e "
已经修改过，请勿重复修改
如果没有生效，或者页面一直转圈圈
请使用 \033[31mShift+F5\033[0m 刷新浏览器缓存
如果一直异常，请执行：\033[31m\"$sap\" restore\033[0m 命令，可以还原修改
如果想强制重新修改，请执行：\033[31m\"$sap\" remod\033[0m 命令，可以还原修改
"
	exit 1
}


contentfornp=/tmp/.contentfornp.tmp

[ -e /usr/sbin/turbostat ] && {
	modprobe msr
	chmod +s /usr/sbin/turbostat
}
echo msr > /etc/modules-load.d/turbostat-msr.conf

cat > $contentfornp << 'EOF'

#modbyshowtempfreq

$res->{thermalstate} = `sensors -A`;
$res->{cpuFreq} = `
	goverf=/sys/devices/system/cpu/cpufreq/policy0/scaling_governor
	maxf=/sys/devices/system/cpu/cpufreq/policy0/cpuinfo_max_freq
	minf=/sys/devices/system/cpu/cpufreq/policy0/cpuinfo_min_freq
	
	cat /proc/cpuinfo | grep -i  "cpu mhz"
	echo -n 'gov:'
	[ -f \$goverf ] && cat \$goverf || echo none
	echo -n 'min:'
	[ -f \$minf ] && cat \$minf || echo none
	echo -n 'max:'
	[ -f \$maxf ] && cat \$maxf || echo none
	echo -n 'pkgwatt:'
	[ -e /usr/sbin/turbostat ] && turbostat --quiet --cpu package --show "PkgWatt" -S sleep 0.25 2>&1 | tail -n1 

`;
EOF



contentforpvejs=/tmp/.contentforpvejs.tmp

cat > $contentforpvejs << 'EOF'
//modbyshowtempfreq
	{
		itemId: 'thermal',
		colspan: 2,
		printBar: false,
		title: gettext('温度(°C)'),
		textField: 'thermalstate',
		renderer:function(value){
			//value进来的值是有换行符的
			console.log(value)
			let b = value.trim().split(/\s+(?=^\w+-)/m).sort();
			let c = b.map(function (v){
				// 风扇转速数据，直接返回
				let fandata = v.match(/(?<=:\s+)[1-9]\d*(?=\s+RPM\s+)/ig)
				if ( fandata ) {
					return '风扇: ' + fandata.join(';')
				}
			
				let name = v.match(/^[^-]+/)[0].toUpperCase();
				
				let temp = v.match(/(?<=:\s+)[+-][\d.]+(?=.?°C)/g);
				// 某些没有数据的传感器,不是温度的传感器
				if ( temp ) {
					temp = temp.map(v => Number(v).toFixed(0))
					
					if (/coretemp/i.test(name)) {
						name = 'CPU';
						temp = temp[0] + ( temp.length > 1 ? ' ( ' +   temp.slice(1).join(' | ') + ' )' : '');
					} else {
						temp = temp[0];
					}
					
					let crit = v.match(/(?<=\bcrit\b[^+]+\+)\d+/);
					
					
					return name + ': ' + temp + ( crit? ` ,crit: ${crit[0]}` : '');
					
				} else {
					return 'null'
				}
				

			});
			console.log(c);
			// 排除null值的
			c=c.filter( v => ! /^null$/.test(v) )
			//console.log(c);
			//排序，把cpu温度放最前
			let cpuIdx = c.findIndex(v => /CPU/i.test(v) );
			if (cpuIdx > 0) {
				c.unshift(c.splice(cpuIdx, 1)[0]);
			}
			
			console.log(c)
			c = c.join(' | ');
			return c;
		 }
	},
EOF


#检测nvme硬盘
echo 检测系统中的NVME硬盘
nvi=0
if $sNVMEInfo;then
	for nvme in $(ls /dev/nvme[0-9] 2> /dev/null); do
		chmod +s /usr/sbin/smartctl

		cat >> $contentfornp << EOF
	\$res->{nvme$nvi} = \`smartctl $nvme -a -j\`;
EOF
		
		
		cat >> $contentforpvejs << EOF
		{
			  itemId: 'nvme${nvi}0',
			  colspan: 2,
			  printBar: false,
			  title: gettext('NVME${nvi}'),
			  textField: 'nvme${nvi}',
			  renderer:function(value){
				//return value;
				try{
					let  v = JSON.parse(value);
					//名字
					let model = v.model_name;
					if (! model) {
						return '找不到硬盘，直通或已被卸载';
					}
					// 温度
					let temp = v.temperature?.current;
					temp = ( temp !== undefined ) ? " | " + temp + '°C' : '' ;
					
					// 通电时间
					let pot = v.power_on_time?.hours;
					let poth = v.power_cycle_count;
					
					pot = ( pot !== undefined ) ? (" | 通电: " + pot + '时' + ( poth ? ',次: '+ poth : '' )) : '';
					
					// 读写
					let log = v.nvme_smart_health_information_log;
					let rw=''
					let health=''
					if (log) {
						let read = log.data_units_read;
						let write = log.data_units_written;
						read = read ? (log.data_units_read / 1956882).toFixed(1) + 'T' : '';
						write = write ? (log.data_units_written / 1956882).toFixed(1) + 'T' : '';
						if (read && write) {
							rw = ' | R/W: ' + read + '/' + write;
						}
						let pu = log.percentage_used;
						let me = log.media_errors;
						if ( pu !== undefined ) {
							health = ' | 健康: ' + ( 100 - pu ) + '%'
							if ( me !== undefined ) {
								health += ',0E: ' + me
							}
						}
					}

					// smart状态
					let smart = v.smart_status?.passed;
					if (smart === undefined ) {
						smart = '';
					} else {
						smart = ' | SMART: ' + (smart ? '正常' : '警告!');
					}
					
					
					let t = model  + temp + health + pot + rw + smart;
					//console.log(t);
					return t;
				}catch(e){
					return '无法获得有效消息';
				};

			 }
		},
EOF
		let nvi++
	done
fi
echo "已添加 $nvi 块NVME硬盘"



#检测机械键盘
echo 检测系统中的SATA固态和机械硬盘
sdi=0
if $sODisksInfo;then
	for sd in $(ls /dev/sd[a-z] 2> /dev/null);do
		chmod +s /usr/sbin/smartctl
		chmod +s /usr/sbin/hdparm
		#检测是否是真的机械键盘
		sdsn=$(awk -F '/' '{print $NF}' <<< $sd)
		sdcr=/sys/block/$sdsn/queue/rotational
		[ -f $sdcr ] || continue
		
		if [ "$(cat $sdcr)" = "0" ];then
			hddisk=false
			sdtype="固态硬盘$sdi"
		else
			hddisk=true
			sdtype="机械硬盘$sdi"
		fi
		
		#[] && 型条件判断，嵌套的条件判断的非 || 后面一定要写动作，否则会穿透到上一层的非条件
		#机械/固态硬盘输出信息逻辑,
		#如果硬盘不存在就输出空JSON

		cat >> $contentfornp << EOF
	\$res->{sd$sdi} = \`
		if [ -b $sd ];then
			if $hddisk && hdparm -C $sd | grep -iq 'standby';then
				echo '{"standy": true}'
			else
				smartctl $sd -a -j
			fi
		else
			echo '{}'
		fi
	\`;
EOF

		cat >> $contentforpvejs << EOF
		{
			  itemId: 'sd${sdi}0',
			  colspan: 2,
			  printBar: false,
			  title: gettext('${sdtype}'),
			  textField: 'sd${sdi}',
			  renderer:function(value){
				//return value;
				try{
					let  v = JSON.parse(value);
					console.log(v)
					if (v.standy === true) {
						return '休眠中'
					}
					
					//名字
					let model = v.model_name;
					if (! model) {
						return '找不到硬盘，直通或已被卸载';
					}
					// 温度
					let temp = v.temperature?.current;
					temp = ( temp !== undefined ) ? " | 温度: " + temp + '°C' : '' ;
					
					// 通电时间
					let pot = v.power_on_time?.hours;
					let poth = v.power_cycle_count;
					
					pot = ( pot !== undefined ) ? (" | 通电: " + pot + '时' + ( poth ? ',次: '+ poth : '' )) : '';
					
					// smart状态
					let smart = v.smart_status?.passed;
					if (smart === undefined ) {
						smart = '';
					} else {
						smart = ' | SMART: ' + (smart ? '正常' : '警告!');
					}
					
					
					let t = model + temp  + pot + smart;
					//console.log(t);
					return t;
				}catch(e){
					return '无法获得有效消息';
				};
			 }
		},
EOF
		let sdi++
	done
fi
echo "已添加 $sdi 块SATA固态和机械硬盘"

echo 开始修改nodes.pm文件
if ! grep -q 'modbyshowtempfreq' $np ;then
	[ ! -e $np.$pvever.bak ] && cp $np $np.$pvever.bak
	
	if [ "$(sed -n "/PVE::pvecfg::version_text()/{=;p;q}" "$np")" ];then #确认修改点
		#r追加文本后面必须跟回车，否则r 后面的文字都会被当成文件名，导致脚本出错
		sed -i "/PVE::pvecfg::version_text()/{
			r $contentfornp
		}" $np
		$dmode && sed -n "/PVE::pvecfg::version_text()/,+5p" $np
	else
		echo '找不到nodes.pm文件的修改点'
		
		fail
	fi
else
	echo 已经修改过
fi

echo 开始修改pvemanagerlib.js文件
if ! grep -q 'modbyshowtempfreq' $pvejs ;then
	[ ! -e $pvejs.$pvever.bak ]  && cp $pvejs $pvejs.$pvever.bak
	
	if [ "$(sed -n '/pveversion/,+3{
			/},/{=;p;q}
		}' $pvejs)" ];then 
		
		sed -i "/pveversion/,+3{
			/},/r $contentforpvejs
		}" $pvejs
		
		$dmode && sed -n "/pveversion/,+8p" $pvejs
	else
		echo '找不到pvemanagerlib.js文件的修改点'
		fail
	fi


	echo 修改页面高度
	#统计加了几条
	addRs=$(grep -c '\$res' $contentfornp)
	addHei=$(( 28 * addRs))
	$dmode && echo "添加了$addRs条内容,增加高度为:${addHei}px"


	#原高度300
	echo 修改左栏高度
	if [ "$(sed -n '/widget.pveNodeStatus/,+4{
			/height:/{=;p;q}
		}' $pvejs)" ]; then 
		
		#获取原高度
		wph=$(sed -n -E "/widget\.pveNodeStatus/,+4{
			/height:/{s/[^0-9]*([0-9]+).*/\1/p;q}
		}" $pvejs)
		
		sed -i -E "/widget\.pveNodeStatus/,+4{
			/height:/{
				s#[0-9]+#$(( wph + addHei))#
			}
		}" $pvejs
		
		$dmode && sed -n '/widget.pveNodeStatus/,+4{
			/height/{
				p;q
			}
		}' $pvejs

		#修改右边栏高度，让它和左边一样高，双栏的时候否则导致浮动出问题
		#原高度325
		echo 修改右栏高度和左栏一致，解决浮动错位
		if [ "$(sed -n '/nodeStatus:\s*nodeStatus/,+10{
				/minHeight:/{=;p;q}
			}' $pvejs)" ]; then 
			#获取原高度
			nph=$(sed -n -E '/nodeStatus:\s*nodeStatus/,+10{
				/minHeight:/{s/[^0-9]*([0-9]+).*/\1/p;q}
			}' "$pvejs")
			
			sed -i -E "/nodeStatus:\s*nodeStatus/,+10{
				/minHeight:/{
					s#[0-9]+#$(( nph + addHei - (nph - wph) ))#
				}
			}" $pvejs
			
			$dmode && sed -n '/nodeStatus:\s*nodeStatus/,+10{
				/minHeight/{
					p;q
				}
			}' $pvejs

		else
			echo 右边栏高度找不到修改点，修改失败
			
		fi

	else
		echo 找不到修改高度的修改点
		fail
	fi

else
	echo 已经修改过
fi


echo 温度，频率，硬盘信息相关修改已完成
echo ------------------------
echo ------------------------
echo 开始修改proxmoxlib.js文件
echo 去除订阅弹窗

plibjs="/usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js"

if ! grep -q 'modbyshowtempfreq' "$plibjs"; then

    [ ! -e "$plibjs.$pvever.bak" ] && cp "$plibjs" "$plibjs.$pvever.bak"
    echo "已备份 proxmoxlib.js 到 proxmoxlib.js.$pvever.bak"

    line_num=$(grep -n "res.data.status.toLowerCase() !== 'active'" "$plibjs" | head -1 | cut -d: -f1)

    if [ -n "$line_num" ]; then
        sed -i "${line_num}s/!==/===/" "$plibjs"
        echo "订阅弹窗已禁用"
        # 添加标记，避免重复修改
        echo "//modbyshowtempfreq" >> "$plibjs"
    else
        echo "未找到订阅弹窗锚点，跳过修改"
    fi

else
    echo "已经修改过"
fi


echo -e "------------------------
修改完成
请刷新浏览器缓存：\033[31mShift+F5\033[0m
如果你看到主页面提示连接错误或者没看到温度和频率，请按：\033[31mShift+F5\033[0m，刷新浏览器缓存！
如果你对效果不满意，请执行：\033[31m\"$sap\" restore\033[0m 命令，可以还原修改
"

systemctl restart pveproxy
