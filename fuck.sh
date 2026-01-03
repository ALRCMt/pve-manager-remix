
#!/bin/bash
# pve-manager-status.sh
# Last Modified: 2025-10-28

echo -e "\n🛠️ \033[1;33;41mPVE-Manager-Status v0.6.0 by MiKing233\033[0m"

echo -e "为你的 ProxmoxVE 节点概要页面添加扩展的硬件监控信息"
echo -e "OpenSource on GitHub (https://github.com/MiKing233/PVE-Manager-Status)\n"

# 先决条件执行判断
# 执行用户判断, 必须为 root 用户执行
if [ "$(id -u)" -ne 0 ]; then
    echo -e "⛔ 请以 root 身份运行此脚本!"
    echo && exit 1
fi

# 执行环境判断, 必须为 Debian 发行版且存在 ProxmoxVE 环境
if ! command -v pveversion &> /dev/null; then
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        if [[ "$ID" != "debian" && "$ID_LIKE" != *"debian"* ]]; then
            echo -e "⛔ 检测到当前系统非 Debian 发行版, 停止执行!"
            echo && exit 1
        fi
    fi
    echo -e "⛔ 未检测到 ProxmoxVE 环境, 停止执行!"
    echo && exit 1
fi

read -p "确认执行吗? [y/N]:" para

# 脚本执行前确认
[[ "$para" =~ ^[Yy]$ ]] || { [[ "$para" =~ ^[Nn]$ ]] && echo -e "\n🚫 操作取消, 未执行任何操作!" && exit 0; echo -e "\n⚠️ 无效输入, 未执行任何操作!"; exit 1; }

nodes="/usr/share/perl5/PVE/API2/Nodes.pm"
pvemanagerlib="/usr/share/pve-manager/js/pvemanagerlib.js"
pvever=$(pveversion | awk -F"/" '{print $2}')

echo -e "\n⚙️ 当前 Proxmox VE 版本: $pvever"



####################   备份步骤   ####################

echo -e "\n💾 修改开始前备份原文件:"

delete_old_backups() {
    local pattern="$1"
    local description="$2"

    shopt -s nullglob
    local files=($pattern)
    shopt -u nullglob

    if [ ${#files[@]} -gt 0 ]; then
        for file in "${files[@]}"; do
            echo "旧备份清理: $file ♻️"
        done
        rm -f "${files[@]}"
    else
        echo "没有发现任何旧备份文件! ♻️"
    fi
}
echo -e "清理旧的备份文件..."
delete_old_backups "${nodes}.*.bak" "nodes"
delete_old_backups "${pvemanagerlib}.*.bak" "pvemanagerlib"

echo -e "备份当前将要被修改的文件..."
cp "$nodes" "${nodes}.${pvever}.bak"
echo "新备份生成: ${nodes}.${pvever}.bak ✅"
cp "$pvemanagerlib" "${pvemanagerlib}.${pvever}.bak"
echo "新备份生成: ${pvemanagerlib}.${pvever}.bak ✅"



####################   依赖检查 & 环境准备   ####################

# 避免重复修改, 重装 pve-manager
# echo -e "\n♻️ 避免重复修改, 重新安装 pve-manager..."
# apt-get install --reinstall -y pve-manager

# 软件包依赖
echo -e "\n🗃️ 检查依赖软件包安装情况..."
packages=(sudo sysstat lm-sensors smartmontools linux-cpupower)
missing=()

# 检查依赖状态
installed_list=$(apt list --installed 2>/dev/null)
for pkg in "${packages[@]}"; do
    if echo "$installed_list" | grep -q "^$pkg/"; then
        echo "$pkg: 已安装✅"
    else
        echo "$pkg: 未安装⛔"
        missing+=("$pkg")
    fi
done

# 安装缺失的包
if [ ${#missing[@]} -ne 0 ]; then
    echo -e "\n📦 检查到软件包缺失: ${missing[*]} 开始安装..."
    if ! (apt-get update && apt-get install -y "${missing[@]}"); then
        echo -e "\n⛔ 依赖软件包安装失败! 请检查你的 apt 源配置或网络连接"
        echo && exit 1
    fi
    echo -e "✅ 依赖软件包已成功安装!"
else
    echo -e "所有依赖软件包均已安装!"
fi

# 配置传感器模块
echo -e "\n🧰 开始配置传感器模块..."
sensors-detect --auto > /tmp/sensors

drivers=$(sed -n '/Chip drivers/,/\#----cut here/p' /tmp/sensors | sed '/Chip /d;/cut/d')

if [ -n "$drivers" ]; then
    echo "发现传感器模块, 正在配置以便开机自动加载"
    for drv in $drivers; do
        modprobe "$drv"
        if grep -qx "$drv" /etc/modules; then
            echo "模块 $drv 已存在于 /etc/modules ➡️"
        else
            echo "$drv" >> /etc/modules
            echo "模块 $drv 已添加至 /etc/modules ✅"
        fi
    done
    if [[ -e /etc/init.d/kmod ]]; then
        echo "正在应用模块配置使其立即生效..."
        /etc/init.d/kmod start &>/dev/null
        echo "模块配置已生效 ✅"
    else
        echo "未找到 /etc/init.d/kmod 跳过此步骤 ➡️"
    fi
    echo "传感器模块已配置完成!"
elif grep -q "No modules to load, skipping modules configuration" /tmp/sensors; then
    echo "未找到需要手动加载的模块, 跳过配置步骤 (可能已由内核自动加载) ➡️"
elif grep -q "Sorry, no sensors were detected" /tmp/sensors; then
    echo "未检测到任何传感器, 跳过配置步骤 (当前环境可能为虚拟机) ⚠️"
else
    echo "发生预期外的错误, 跳过配置步骤! 你的设备可能不支持或内核未包含相关模块 ⛔"
fi

rm -f /tmp/sensors

# 配置必要的执行权限 (替代危险的 chmod +s)
echo -e "\n🔩 配置必要的执行权限..."
echo -e "允许 www-data 用户以 sudo 权限执行特定监控命令"
SUDOERS_FILE="/etc/sudoers.d/pve-manager-status"
# 首先移除可能被添加的 SUID 权限设置, 以防曾经被其它监控脚本添加
binaries=(/usr/sbin/nvme /usr/bin/iostat /usr/bin/sensors /usr/bin/cpupower /usr/sbin/smartctl /usr/sbin/turbostat)
for bin in "${binaries[@]}"; do
    if [[ -e $bin && -u $bin ]]; then
        chmod -s "$bin" && echo "检测到不安全的 SUID 权限已移除: $bin ⚠️"
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
    echo "sudoers 规则语法检查通过 ✅"
    mv "${TMP_SUDOERS}" "${SUDOERS_FILE}"
    chown root:root "${SUDOERS_FILE}"
    chmod 0440 "${SUDOERS_FILE}"
    echo "已成功配置 sudo 规则于: ${SUDOERS_FILE} 🔐"
else
    echo "⛔ sudoers 规则语法错误, 操作终止!"
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

echo -e "\n📋 添加概要页面硬件监控信息..."

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
    echo "⛔ 在 $nodes 中未找到锚点, 操作终止!"
    rm -f "$tmpf1"
    echo -e "⚠️ 锚点'PVE::pvecfg::version_text', 文件可能已更新或与当前版本不兼容\n" && exit 1
fi

# 应用更改
sed -i '/PVE::pvecfg::version_text/ r '"$tmpf1"'' "$nodes"

# 验证修改是否成功
if grep -q 'cpupower' "$nodes"; then
    echo "已完成修改: $nodes ✅"
else
    echo "⛔ 检查对 $nodes 添加的内容未生效!"
    rm -f "$tmpf1"
    echo -e "⚠️ 请检查文件权限或手动检查文件内容\n" && exit 1
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
                const w0 = value.split('\n')[0].split(' ')[0];
                const w1 = value.split('\n')[1].split(' ')[0];
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
                const f0 = value.match(/cpu MHz.*?([\d]+)/)[1];
                const f1 = value.match(/CPU min MHz.*?([\d]+)/)[1];
                const f2 = value.match(/CPU max MHz.*?([\d]+)/)[1];
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
    echo "⛔ 在 $pvemanagerlib 中计算插入位置失败, 操作终止!"
    rm -f "$tmpf2"
    echo -e "⚠️ 锚点'pveversion', 文件可能已更新或与当前版本不兼容\n" && exit 1
fi

# 应用更改
sed -i "${ln}r $tmpf2" "$pvemanagerlib"

# 验证修改是否成功
if grep -q "itemId: 'cpupower'" "$pvemanagerlib"; then
    echo "已完成修改: $pvemanagerlib ✅"
else
    echo "⛔ 检查对 $pvemanagerlib 添加的内容未生效!"
    rm -f "$tmpf2"
    echo -e "⚠️ 请检查文件权限或手动检查文件内容\n" && exit 1
fi

rm -f "$tmpf2"



####################   zh-CN 本地化   ####################

echo -e "\n🌏 添加缺失的 zh-CN 翻译..."

pve_major_ver=$(echo "$pvever" | cut -d'.' -f1)

case "$pve_major_ver" in
    "8")
        # PVE 8.x: 为 Network traffic 图表添加中文 fieldTitles
        if ! grep -q "fields: \['netin', 'netout'\]" "$pvemanagerlib"; then
            echo -e "⛔ 未找到 Network traffic 的锚点, 操作终止!"
            echo -e "⚠️ 锚点 \"fields: ['netin', 'netout']\", 文件可能已更新或与当前版本不兼容\n" && exit 1
        else
            if grep -q "fieldTitles: \[gettext('传入'), gettext('发送')\]" "$pvemanagerlib"; then
                echo -e "Network traffic 的中文翻译已存在, 跳过该步骤 ➡️"
            else
                sed -i "s/^\( *\)fields: \['netin', 'netout'\],/&\n\1fieldTitles: [gettext('传入'), gettext('发送')],/" "$pvemanagerlib"
                if grep -q "fieldTitles: \[gettext('传入'), gettext('发送')\]" "$pvemanagerlib"; then
                    echo -e "已添加 PVE 8.x 缺失的翻译: 网络流量 图表上的 (传入)和(发送)按钮 ✅"
                else
                    echo -e "⛔ 检查对 Network traffic 部分的中文 fieldTitles 修改未生效!"
                    echo -e "⚠️ 请检查文件权限或手动检查文件内容\n" && exit 1
                fi
            fi
        fi

        # PVE 8.x: 为 Disk IO 图表添加中文 fieldTitles
        if ! grep -q "fields: \['diskread', 'diskwrite'\]" "$pvemanagerlib"; then
            echo -e "⛔ 未找到 Disk IO 的锚点, 操作终止!"
            echo -e "⚠️ 锚点 \"fields: ['diskread', 'diskwrite']\", 文件可能已更新或与当前版本不兼容\n" && exit 1
        else
            if grep -q "fieldTitles: \[gettext('读取'), gettext('写入')\]" "$pvemanagerlib"; then
                echo -e "Disk IO 的中文翻译已存在, 跳过该步骤 ➡️"
            else
                sed -i "s/^\( *\)fields: \['diskread', 'diskwrite'\],/&\n\1fieldTitles: [gettext('读取'), gettext('写入')],/" "$pvemanagerlib"
                if grep -q "fieldTitles: \[gettext('读取'), gettext('写入')\]" "$pvemanagerlib"; then
                    echo -e "已添加 PVE 8.x 缺失的翻译: 磁盘IO 图表上的 (读取)和(写入)按钮 ✅"
                else
                    echo -e "⛔ 检查对 Disk IO 部分的中文 fieldTitles 修改未生效!"
                    echo -e "⚠️ 请检查文件权限或手动检查文件内容\n" && exit 1
                fi
            fi
        fi
        ;;
    "9")
        echo -e "PVE 9.X 的 zh-CN 本地化将在未来的版本中支持, 跳过该步骤 ➡️"
        ;;
    *)
        echo -e "\n⚠️ 不支持的PVE版本($pvever), 跳过 zh-CN 本地化."
        ;;
esac



####################   调整页面高度   ####################

echo -e "\n🎚️ 调整修改后的页面高度..."

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
echo "页面高度经计算模型已动态调整为 ${new_height}px ✅"

ln=$(expr $(sed -n -e '/widget.pveDcGuests/=' $pvemanagerlib) + 10)
sed -i "${ln}a\ textAlign: 'right'," $pvemanagerlib
ln=$(expr $(sed -n -e '/widget.pveNodeStatus/=' $pvemanagerlib) + 10)
sed -i "${ln}a\ textAlign: 'right'," $pvemanagerlib



# 在脚本末尾添加服务重启逻辑

####################   脚本末尾服务重启   ####################
 echo -e "\n🔁 等待服务 pveproxy.service 重启..."
timeout 10s systemctl restart pveproxy.service &> /dev/null
#restart_status=$?
#if [ $restart_status -ne 0 ]; then
#     if [ $restart_status -eq 124 ]; then
#        echo -e "\n⛔ 重启服务 pveproxy.service 超时 (timeout 10s)"
#    else
#        echo -e "\n⛔ 重启服务 pveproxy.service 失败 ($restart_status)"
#    fi
#    echo -e "\n⚠️ 请检查服务状态信息以排查问题\n"
#    systemctl status pveproxy.service --no-pager
#    echo && exit 1
# fi

echo -e "\n✅ 修改完成, 请使用 Ctrl + F5 刷新浏览器 Proxmox VE Web 管理页面缓存\n"
