#!/usr/bin/env bash

# Merged script, ensuring pve-manager-status.sh runs first, then showtempcpufreq.sh
# version: 2026.1.3

# --------------------
# Content of pve-manager-status.sh
# --------------------

#!/bin/bash
# pve-manager-status.sh
# Last Modified: 2025-10-28

echo -e "\n🛠️ \033[1;33;41mPVE-Manager-Status v0.6.0 by MiKing233\033[0m"

echo -e "Add extended hardware monitoring information to your ProxmoxVE node summary page"
echo -e "OpenSource on GitHub (https://github.com/MiKing233/PVE-Manager-Status)\n"

# Prerequisites check
# Must be run as root
if [ "$(id -u)" -ne 0 ]; then
    echo -e "⛔ Please run this script as root!"
    echo && exit 1
fi

# Environment check, must be Debian and ProxmoxVE environment
if ! command -v pveversion &> /dev/null; then
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        if [[ "$ID" != "debian" && "$ID_LIKE" != *"debian"* ]]; then
            echo -e "⛔ Non-Debian distribution detected, stopping execution!"
            echo && exit 1
        fi
    fi
    echo -e "⛔ ProxmoxVE environment not detected, stopping execution!"
    echo && exit 1
fi

read -p "Confirm execution? [y/N]:" para

# Confirmation before execution
[[ "$para" =~ ^[Yy]$ ]] || { [[ "$para" =~ ^[Nn]$ ]] && echo -e "\n🚫 Operation cancelled, no actions taken!" && exit 0; echo -e "\n⚠️ Invalid input, no actions taken!"; exit 1; }

nodes="/usr/share/perl5/PVE/API2/Nodes.pm"
pvemanagerlib="/usr/share/pve-manager/js/pvemanagerlib.js"
pvever=$(pveversion | awk -F"/" '{print $2}')

echo -e "\n⚙️ Current Proxmox VE version: $pvever"



####################   Backup Step   ####################

echo -e "\n💾 Backing up original files before modification:"

delete_old_backups() {
    local pattern="$1"
    local description="$2"

    shopt -s nullglob
    local files=($pattern)
    shopt -u nullglob

    if [ ${#files[@]} -gt 0 ]; then
        for file in "${files[@]}"; do
            echo "Old backup cleaned: $file ♻️"
        done
        rm -f "${files[@]}"
    else
        echo "No old backup files found! ♻️"
    fi
}
echo -e "Cleaning up old backup files..."
delete_old_backups "${nodes}.*.bak" "nodes"
delete_old_backups "${pvemanagerlib}.*.bak" "pvemanagerlib"

echo -e "Backing up files to be modified..."
cp "$nodes" "${nodes}.${pvever}.bak"
echo "New backup generated: ${nodes}.${pvever}.bak ✅"
cp "$pvemanagerlib" "${pvemanagerlib}.${pvever}.bak"
echo "New backup generated: ${pvemanagerlib}.${pvever}.bak ✅"



####################   Dependency Check & Preparation   ####################

# Reinstall pve-manager to avoid duplicate modifications
echo -e "\n♻️ Reinstalling pve-manager to ensure a clean state..."
apt-get install --reinstall -y pve-manager

# Package dependencies
echo -e "\n🗃️ Checking dependency package installation..."
packages=(sudo sysstat lm-sensors smartmontools linux-cpupower)
missing=()

# Check installation status
installed_list=$(apt list --installed 2>/dev/null)
for pkg in "${packages[@]}"; do
    if echo "$installed_list" | grep -q "^$pkg/"; then
        echo "$pkg: Installed ✅"
    else
        echo "$pkg: Not installed ⛔"
        missing+=("$pkg")
    fi
done

# Install missing packages
if [ ${#missing[@]} -ne 0 ]; then
    echo -e "\n📦 Missing packages detected: ${missing[*]} Starting installation..."
    if ! (apt-get update && apt-get install -y "${missing[@]}"); then
        echo -e "\n⛔ Dependency installation failed! Please check your apt sources or network connection."
        echo && exit 1
    fi
    echo -e "✅ Dependencies installed successfully!"
else
    echo -e "All dependencies are installed!"
fi

# Configure sensor modules
echo -e "\n🧰 Configuring sensor modules..."
sensors-detect --auto > /tmp/sensors

drivers=$(sed -n '/Chip drivers/,/\#----cut here/p' /tmp/sensors | sed '/Chip /d;/cut/d')

if [ -n "$drivers" ]; then
    echo "Sensor modules found, configuring for auto-load at boot..."
    for drv in $drivers; do
        modprobe "$drv"
        if grep -qx "$drv" /etc/modules; then
            echo "Module $drv already exists in /etc/modules ➡️"
        else
            echo "$drv" >> /etc/modules
            echo "Module $drv added to /etc/modules ✅"
        fi
    done
    if [[ -e /etc/init.d/kmod ]]; then
        echo "Applying module configuration to take effect immediately..."
        /etc/init.d/kmod start &>/dev/null
        echo "Module configuration applied ✅"
    else
        echo "/etc/init.d/kmod not found, skipping this step ➡️"
    fi
    echo "Sensor modules configuration completed!"
elif grep -q "No modules to load, skipping modules configuration" /tmp/sensors; then
    echo "No modules found to load manually, skipping (may be auto-loaded by kernel) ➡️"
elif grep -q "Sorry, no sensors were detected" /tmp/sensors; then
    echo "No sensors detected, skipping (current environment might be a VM) ⚠️"
else
    echo "Unexpected error, skipping configuration! Your device might not be supported or the kernel lacks relevant modules ⛔"
fi

rm -f /tmp/sensors

# Configure necessary execution permissions
echo -e "\n🔩 Configuring necessary execution permissions..."
echo -e "Allowing www-data user to execute specific monitoring commands via sudo"
SUDOERS_FILE="/etc/sudoers.d/pve-manager-status"
# Remove any existing SUID permissions for safety
binaries=(/usr/sbin/nvme /usr/bin/iostat /usr/bin/sensors /usr/bin/cpupower /usr/sbin/smartctl /usr/sbin/turbostat)
for bin in "${binaries[@]}"; do
    if [[ -e $bin && -u $bin ]]; then
        chmod -s "$bin" && echo "Insecure SUID permission removed: $bin ⚠️"
    fi
done

# Define absolute paths for sudo commands
IOSTAT_PATH=$(command -v iostat)
SENSORS_PATH=$(command -v sensors)
SMARTCTL_PATH=$(command -v smartctl)
TURBOSTAT_PATH=$(command -v turbostat)

# Configure sudoers rule content
echo -e "Configuring sudoers rules and performing syntax check..."
read -r -d '' SUDOERS_CONTENT << EOM
# Allow www-data user (PVE Web GUI) to run specific hardware monitoring commands
# This file is managed by pve-manager-status.sh (https://github.com/MiKing233/PVE-Manager-Status)

www-data ALL=(root) NOPASSWD: ${SENSORS_PATH}
www-data ALL=(root) NOPASSWD: ${SMARTCTL_PATH} -a /dev/*
www-data ALL=(root) NOPASSWD: ${IOSTAT_PATH} -d -x -k 1 1
www-data ALL=(root) NOPASSWD: ${TURBOSTAT_PATH} -S -q -s PkgWatt -i 0.1 -n 1 -c package
EOM

# Use visudo for syntax check before applying
TMP_SUDOERS=$(mktemp)
echo "${SUDOERS_CONTENT}" > "${TMP_SUDOERS}"

if visudo -c -f "${TMP_SUDOERS}" &> /dev/null; then
    echo "sudoers rule syntax check passed ✅"
    mv "${TMP_SUDOERS}" "${SUDOERS_FILE}"
    chown root:root "${SUDOERS_FILE}"
    chmod 0440 "${SUDOERS_FILE}"
    echo "Sudo rules successfully configured at: ${SUDOERS_FILE} 🔐"
else
    echo "⛔ sudoers rule syntax error, operation terminated!"
    echo -e "\n--- DEBUG INFO START ---"
    echo "Generated sudoers rules:"
    echo "--------------------------------------------------"
    cat "${TMP_SUDOERS}"
    echo "--------------------------------------------------"
    echo
    echo "Detailed visudo syntax check errors:"
    echo "--------------------------------------------------"
    visudo -c -f "${TMP_SUDOERS}"
    echo "--------------------------------------------------"
    echo -e "\n--- DEBUG INFO END ---"
    rm -f "${TMP_SUDOERS}"
    echo && exit 1
fi

# Ensure msr module is loaded for turbostat support
modprobe msr && echo msr > /etc/modules-load.d/turbostat-msr.conf



####################   Summary Page Implementation   ####################

echo -e "\n📋 Adding hardware monitoring information to summary page..."

# Modify node.pm
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

# Check for anchor before modification
if ! grep -q 'PVE::pvecfg::version_text' "$nodes"; then
    echo "⛔ Anchor not found in $nodes, operation terminated!"
    rm -f "$tmpf1"
    echo -e "⚠️ Anchor 'PVE::pvecfg::version_text' not found. The file may have been updated or is incompatible.\n" && exit 1
fi

# Apply changes
sed -i '/PVE::pvecfg::version_text/ r '"$tmpf1"'' "$nodes"

# Verify modification
if grep -q 'cpupower' "$nodes"; then
    echo "Modification completed: $nodes ✅"
else
    echo "⛔ Check failed: changes to $nodes did not take effect!"
    rm -f "$tmpf1"
    echo -e "⚠️ Please check file permissions or manually inspect the content\n" && exit 1
fi

rm -f "$tmpf1"



# Modify pvemanagerlib.js
tmpf2=$(mktemp /tmp/pve-manager-status.XXXXXX) || exit 1
cat > "$tmpf2" << 'EOF'
        {
            itemId: 'cpupower',
            colspan: 2,
            printBar: false,
            title: gettext('CPU Power'),
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
                return `Governor: ${colorizeCpuMode(w0)} | CPU Power: ${colorizeCpuPower(w1)}`
            }
        },
        {
            itemId: 'cpufreq',
            colspan: 2,
            printBar: false,
            title: gettext('CPU Frequency'),
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
                return `Real-time: ${colorizeCpuFreq(f0)} | Min: ${f1} MHz | Max: ${f2} MHz `
            }
        },
        {
            itemId: 'sensors',
            colspan: 2,
            printBar: false,
            title: gettext('Sensors'),
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
                    if (rpmNum < 1500) return `<span style="color:green; font-weight:bold;">${rpm} RPM</span>`;
                    if (rpmNum < 3000) return `<span style="color:orange; font-weight:bold;">${rpm} RPM</span>`;
                    return `<span style="color:red; font-weight:bold;">${rpm} RPM</span>`;
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
                        var corecombi = `Core ${core[1]}: ${colorizeCpuTemp(core[2])}`
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
                                output += 'iGPU: ';
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
                                output += 'MB: ';
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
                                output += 'Fans: ';
                                if (FunState.cpufans.length > 0) {
                                    output += 'CPU-';
                                    for (const cpufan_value of FunState.cpufans) {
                                        output += `${colorizeFanRpm(cpufan_value)}, `;
                                    }
                                }

                                if (FunState.motherboardfans.length > 0) {
                                    output += 'MB-';
                                    for (const motherboardfan_value of FunState.motherboardfans) {
                                        output += `${colorizeFanRpm(motherboardfan_value)}, `;
                                    }
                                }

                                if (FunState.pumpfans.length > 0) {
                                    output += 'Pump-';
                                    for (const pumpfan_value of FunState.pumpfans) {
                                        output += `${colorizeFanRpm(pumpfan_value)}, `;
                                    }
                                }

                                if (FunState.systemfans.length > 0) {
                                    if (FunState.cpufans.length > 0 || FunState.pumpfans.length > 0) {
                                        output += 'SYS-';
                                    }
                                    for (const systemfan_value of FunState.systemfans) {
                                        output += `${colorizeFanRpm(systemfan_value)}, `;
                                    }
                                }
                                output = output.slice(0, -2);
                                output += ' | ';
                            } else if (FunState.cpufans.length == 0 && FunState.pumpfans.length == 0 && FunState.systemfans.length == 0) {
                                output += ' Fans: Stopped';
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
            title: gettext('Core Frequency'),
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
                    frequencies.push(`Thread ${coreNum}: ${colorizeCpuFreq(parseInt(match[1]))}`);
                }

                if (frequencies.length === 0) {
                    return 'Unable to fetch CPU frequency info';
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

# Calculate insertion line number
ln=$(sed -n '/pveversion/,+10{/},/{=;q}}' $pvemanagerlib)

# Check for valid line number
if ! [[ "$ln" =~ ^[0-9]+$ ]]; then
    echo "⛔ Failed to calculate insertion point in $pvemanagerlib, operation terminated!"
    rm -f "$tmpf2"
    echo -e "⚠️ Anchor 'pveversion' not found. The file may have been updated or is incompatible.\n" && exit 1
fi

# Apply changes
sed -i "${ln}r $tmpf2" "$pvemanagerlib"

# Verify modification
if grep -q "itemId: 'cpupower'" "$pvemanagerlib"; then
    echo "Modification completed: $pvemanagerlib ✅"
else
    echo "⛔ Check failed: changes to $pvemanagerlib did not take effect!"
    rm -f "$tmpf2"
    echo -e "⚠️ Please check file permissions or manually inspect the content\n" && exit 1
fi

rm -f "$tmpf2"



####################   zh-CN Localization (Translation Fixes)   ####################

echo -e "\n🌏 Adding missing translations..."

pve_major_ver=$(echo "$pvever" | cut -d'.' -f1)

case "$pve_major_ver" in
    "8")
        # PVE 8.x: Add translated fieldTitles for Network Traffic
        if ! grep -q "fields: \['netin', 'netout'\]" "$pvemanagerlib"; then
            echo -e "⛔ Anchor for Network Traffic not found, operation terminated!"
            echo -e "⚠️ Anchor \"fields: ['netin', 'netout']\" not found. File may be incompatible.\n" && exit 1
        else
            if grep -q "fieldTitles: \[gettext('Incoming'), gettext('Outgoing')\]" "$pvemanagerlib"; then
                echo -e "Translations for Network Traffic already exist, skipping ➡️"
            else
                sed -i "s/^\( *\)fields: \['netin', 'netout'\],/&\n\1fieldTitles: [gettext('Incoming'), gettext('Outgoing')],/" "$pvemanagerlib"
                if grep -q "fieldTitles: \[gettext('Incoming'), gettext('Outgoing')\]" "$pvemanagerlib"; then
                    echo -e "Added PVE 8.x translations: (Incoming) and (Outgoing) buttons on Network Traffic chart ✅"
                else
                    echo -e "⛔ Check failed: modifications to Network Traffic translations did not take effect!"
                    echo -e "⚠️ Please check file permissions or manually inspect the content\n" && exit 1
                fi
            fi
        fi

        # PVE 8.x: Add translated fieldTitles for Disk IO
        if ! grep -q "fields: \['diskread', 'diskwrite'\]" "$pvemanagerlib"; then
            echo -e "⛔ Anchor for Disk IO not found, operation terminated!"
            echo -e "⚠️ Anchor \"fields: ['diskread', 'diskwrite']\" not found. File may be incompatible.\n" && exit 1
        else
            if grep -q "fieldTitles: \[gettext('Read'), gettext('Write')\]" "$pvemanagerlib"; then
                echo -e "Translations for Disk IO already exist, skipping ➡️"
            else
                sed -i "s/^\( *\)fields: \['diskread', 'diskwrite'\],/&\n\1fieldTitles: [gettext('Read'), gettext('Write')],/" "$pvemanagerlib"
                if grep -q "fieldTitles: \[gettext('Read'), gettext('Write')\]" "$pvemanagerlib"; then
                    echo -e "Added PVE 8.x translations: (Read) and (Write) buttons on Disk IO chart ✅"
                else
                    echo -e "⛔ Check failed: modifications to Disk IO translations did not take effect!"
                    echo -e "⚠️ Please check file permissions or manually inspect the content\n" && exit 1
                fi
            fi
        fi
        ;;
    "9")
        echo -e "PVE 9.X localization will be supported in future versions, skipping ➡️"
        ;;
    *)
        echo -e "\n⚠️ Unsupported PVE version ($pvever), skipping localization fixes."
        ;;
esac



####################   Adjust Page Height   ####################

echo -e "\n🎚️ Adjusting page height after modification..."

calculate_height_increase() {
    local total_lines=0
    local module_count=0

    # itemId:cpupower: 1 line
    total_lines=$((total_lines + 1))
    module_count=$((module_count + 1))

    # itemId:cpufreq: 1 line
    total_lines=$((total_lines + 1))
    module_count=$((module_count + 1))

    # itemId:sensors: 1 base line
    total_lines=$((total_lines + 1))
    module_count=$((module_count + 1))
    local core_temp_count=$(sudo sensors 2>/dev/null | grep -c '^Core')
    if [ "$core_temp_count" -gt 1 ]; then
        local sensor_core_lines=$(((core_temp_count + 4 - 1) / 4))
        total_lines=$((total_lines + sensor_core_lines))
    fi

    # itemId:corefreq: 0 base lines
    module_count=$((module_count + 1))
    local thread_count=$(grep -c ^processor /proc/cpuinfo)
    if [ "$thread_count" -gt 0 ]; then
        local core_freq_lines=$(((thread_count + 4 - 1) / 4))
        total_lines=$((total_lines + core_freq_lines))
    fi

    local height_increase=$((total_lines * 17 + module_count * 7))
    echo $height_increase
}

height_increase=$(calculate_height_increase)
new_height=$((350 + height_increase))

sed -i -E "/Ext.define\('PVE.node.StatusView'/,/height:/{s/height: *[0-9]+,/height: $new_height,/}" "$pvemanagerlib"
echo "Page height dynamically adjusted to ${new_height}px ✅"

ln=$(expr $(sed -n -e '/widget.pveDcGuests/=' $pvemanagerlib) + 10)
sed -i "${ln}a\ textAlign: 'right'," $pvemanagerlib
ln=$(expr $(sed -n -e '/widget.pveNodeStatus/=' $pvemanagerlib) + 10)
sed -i "${ln}a\ textAlign: 'right'," $pvemanagerlib

echo -e "\n✅ Modification complete! Please use Ctrl + F5 to refresh your Proxmox VE Web GUI browser cache.\n"


# --------------------
# Content of showtempcpufreq.sh
# --------------------

#!/usr/bin/env bash

# version: 2023.9.5
# Control variables for disk information
# NVME disks
sNVMEInfo=true
# SSD and HDD
sODisksInfo=true
# debug mode
dmode=false

# Script path
sdir=$(cd "$(dirname "${BASH_SOURCE[0]}")"; pwd)
cd "$sdir"

sname=$(basename "${BASH_SOURCE[0]}")
sap=$sdir/$sname
echo "Script path: $sap"

# Files to modify
np=/usr/share/perl5/PVE/API2/Nodes.pm
pvejs=/usr/share/pve-manager/js/pvemanagerlib.js
plibjs=/usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js

if ! command -v sensors > /dev/null; then
	echo "You need to install lm-sensors and linux-cpupower. Attempting auto-installation..."
	if apt update ; apt install -y lm-sensors; then 
		echo "lm-sensors installed successfully"
		
		echo "Attempting to install linux-cpupower for power consumption info..."
		if apt install -y linux-cpupower;then
			echo "linux-cpupower installed successfully"
		else
			echo -e "linux-cpupower installation failed. Power info might be unavailable. Manual install: \033[34mapt update ; apt install linux-cpupower && modprobe msr && echo msr > /etc/modules-load.d/turbostat-msr.conf && chmod +s /usr/sbin/turbostat\033[0m"
		fi
	else
		echo "Script failed to auto-install dependencies."
		echo -e "Please use the command: \033[34mapt update ; apt install -y lm-sensors linux-cpupower && chmod +s /usr/sbin/turbostat\033[0m to install manually and rerun the script."
		echo "Script exiting"
		exit 1
	fi
fi


# Get version
pvever=$(pveversion | awk -F"/" '{print $2}')
echo "Your PVE version: $pvever"

restore() {
	[ -e $np.$pvever.bak ]     && mv $np.$pvever.bak $np
	[ -e $pvejs.$pvever.bak ]  && mv $pvejs.$pvever.bak $pvejs
	[ -e $plibjs.$pvever.bak ] && mv $plibjs.$pvever.bak $plibjs
}

fail() {
	echo "Modification failed, possibly incompatible with PVE version $pvever. Restoring..."
	restore
	echo "Restore completed"
	exit 1
}

# Restore logic
case $1 in 
	restore)
		restore
		echo "Modifications restored"
		
		if [ "$2" != 'remod' ];then 
			echo -e "Please refresh browser cache: \033[31mShift+F5\033[0m"
			systemctl restart pveproxy
		else 
			echo -----
		fi
		
		exit 0
	;;
	remod)
		echo "Forcing re-modification..."
		echo -----------
		"$sap" restore remod > /dev/null 
		"$sap"
		exit 0
	;;
esac

# Check if already modified
[ $(grep 'modbyshowtempfreq' $np $pvejs $plibjs | wc -l) -eq 3 ]  && {
	echo -e "
Already modified. Do not repeat.
If not working or page is loading indefinitely,
please use \033[31mShift+F5\033[0m to refresh browser cache.
If issues persist, run: \033[31m\"$sap\" restore\033[0m to revert,
or \033[31m\"$sap\" remod\033[0m to force re-modify.
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
		title: gettext('Temperature(°C)'),
		textField: 'thermalstate',
		renderer:function(value){
			// value has newlines
			console.log(value)
			let b = value.trim().split(/\s+(?=^\w+-)/m).sort();
			let c = b.map(function (v){
				// Fan speed data
				let fandata = v.match(/(?<=:\s+)[1-9]\d*(?=\s+RPM\s+)/ig)
				if ( fandata ) {
					return 'Fans: ' + fandata.join(';')
				}
			
				let name = v.match(/^[^-]+/)[0].toUpperCase();
				
				let temp = v.match(/(?<=:\s+)[+-][\d.]+(?=.?°C)/g);
				// Non-temperature or missing sensors
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
			// Filter out nulls
			c=c.filter( v => ! /^null$/.test(v) )
			// Sort CPU to top
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


# NVME detection
echo "Detecting NVME drives in the system..."
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
				try{
					let  v = JSON.parse(value);
					let model = v.model_name;
					if (! model) {
						return 'Drive not found, passed through or unmounted';
					}
					let temp = v.temperature?.current;
					temp = ( temp !== undefined ) ? " | Temp: " + temp + '°C' : '' ;
					
					let pot = v.power_on_time?.hours;
					let poth = v.power_cycle_count;
					
					pot = ( pot !== undefined ) ? (" | Power On: " + pot + 'h' + ( poth ? ', Cycles: '+ poth : '' )) : '';
					
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
							health = ' | Health: ' + ( 100 - pu ) + '%'
							if ( me !== undefined ) {
								health += ', 0E: ' + me
							}
						}
					}

					let smart = v.smart_status?.passed;
					if (smart === undefined ) {
						smart = '';
					} else {
						smart = ' | SMART: ' + (smart ? 'OK' : 'WARNING!');
					}
					
					
					let t = model  + temp + health + pot + rw + smart;
					return t;
				}catch(e){
					return 'Unable to retrieve valid information';
				};

			 }
		},
EOF
		let nvi++
	done
fi
echo "Added $nvi NVME drive(s)"



# SATA detection
echo "Detecting SATA SSDs and HDDs in the system..."
sdi=0
if $sODisksInfo;then
	for sd in $(ls /dev/sd[a-z] 2> /dev/null);do
		chmod +s /usr/sbin/smartctl
		chmod +s /usr/sbin/hdparm
		sdsn=$(awk -F '/' '{print $NF}' <<< $sd)
		sdcr=/sys/block/$sdsn/queue/rotational
		[ -f $sdcr ] || continue
		
		if [ "$(cat $sdcr)" = "0" ];then
			hddisk=false
			sdtype="SSD $sdi"
		else
			hddisk=true
			sdtype="HDD $sdi"
		fi
		
		cat >> $contentfornp << EOF
	\$res->{sd$sdi} = \`
		if [ -b $sd ];then
			if $hddisk && hdparm -C $sd | grep -iq 'standby';then
				echo '{"standby": true}'
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
				try{
					let  v = JSON.parse(value);
					console.log(v)
					if (v.standby === true) {
						return 'Standby'
					}
					
					let model = v.model_name;
					if (! model) {
						return 'Drive not found, passed through or unmounted';
					}
					let temp = v.temperature?.current;
					temp = ( temp !== undefined ) ? " | Temp: " + temp + '°C' : '' ;
					
					let pot = v.power_on_time?.hours;
					let poth = v.power_cycle_count;
					
					pot = ( pot !== undefined ) ? (" | Power On: " + pot + 'h' + ( poth ? ', Cycles: '+ poth : '' )) : '';
					
					let smart = v.smart_status?.passed;
					if (smart === undefined ) {
						smart = '';
					} else {
						smart = ' | SMART: ' + (smart ? 'OK' : 'WARNING!');
					}
					
					
					let t = model + temp  + pot + smart;
					return t;
				}catch(e){
					return 'Unable to retrieve valid information';
				};
			 }
		},
EOF
		let sdi++
	done
fi
echo "Added $sdi SATA SSD/HDD(s)"

echo "Starting modification of nodes.pm..."
if ! grep -q 'modbyshowtempfreq' $np ;then
	[ ! -e $np.$pvever.bak ] && cp $np $np.$pvever.bak
	
	if [ "$(sed -n "/PVE::pvecfg::version_text()/{=;p;q}" "$np")" ];then
		sed -i "/PVE::pvecfg::version_text()/{
			r $contentfornp
		}" $np
		$dmode && sed -n "/PVE::pvecfg::version_text()/,+5p" $np
	else
		echo 'Anchor not found in nodes.pm'
		
		fail
	fi
else
	echo "Already modified"
fi

echo "Starting modification of pvemanagerlib.js..."
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
		echo 'Anchor not found in pvemanagerlib.js'
		fail
	fi


	echo "Modifying page height..."
	addRs=$(grep -c '\$res' $contentfornp)
	addHei=$(( 28 * addRs))
	$dmode && echo "Added $addRs items, increasing height by: ${addHei}px"


	echo "Modifying left column height..."
	if [ "$(sed -n '/widget.pveNodeStatus/,+4{
			/height:/{=;p;q}
		}' $pvejs)" ]; then 
		
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

		echo "Modifying right column height to match left column to fix float issues..."
		if [ "$(sed -n '/nodeStatus:\s*nodeStatus/,+10{
				/minHeight:/{=;p;q}
			}' $pvejs)" ]; then 
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
			echo "Anchor for right column height not found, modification failed"
			
		fi

	else
		echo "Anchor for height modification not found"
		fail
	fi

else
	echo "Already modified"
fi


echo "Temperature, Frequency, and Disk info modifications complete"
echo "------------------------"
echo "------------------------"
echo "Starting modification of proxmoxlib.js..."
echo "Removing subscription popup..."

if ! grep -q 'modbyshowtempfreq' $plibjs ;then

	[ ! -e $plibjs.$pvever.bak ] && cp $plibjs $plibjs.$pvever.bak
	
	if [ "$(sed -n '/\/nodes\/localhost\/subscription/{=;p;q}' $plibjs)" ];then 
		sed -i '/\/nodes\/localhost\/subscription/,+10{
			/res === null/{
				N
				s/(.*)/(false)/
				a //modbyshowtempfreq
			}
		}' $plibjs
		
		$dmode && sed -n "/\/nodes\/localhost\/subscription/,+10p" $plibjs
	else 
		echo "Anchor not found, skipping subscription popup removal"
	fi
else
	echo "Already modified"
fi
echo -e "------------------------
Modification complete
Please refresh browser cache: \033[31mShift+F5\033[0m
If you see connection errors or don't see info, press \033[31mShift+F5\033[0m!
If unsatisfied, run: \033[31m\"$sap\" restore\033[0m to revert.
"

systemctl restart pveproxy
