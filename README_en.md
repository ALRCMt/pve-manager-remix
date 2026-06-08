# PVE-Manager-remix

| [简体中文](/README.md) | English |

ALRCMt merged the hardware monitoring information into the Proxmox VE node summary page.
The current version is adapted for PVE 9.x.

I only performed integration and conflict-resolution work; the summary content is entirely from the following two contributors. Thanks to them for their contributions:
https://github.com/MiKing233/PVE-Manager-Status
https://github.com/a904055262/PVE-manager-status

The current script is more suitable for AMD usage (maybe?).
It merges SATA and NVMe hard disk-related content from a904055262's script and CPU frequency and power consumption-related content from MiKing233's script.
Because I am a beginner, I follow the principle of "if it works, don't change it," so the script is very redundant. I'm not going to touch it.
<img width="200" alt="image" src="/images/meme1.png" />

One-click script, after execution, refresh using Ctrl + F5:
``` bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/ALRCMt/pve-manager-remix/refs/heads/main/merged-script-en.sh)"
```

If an error occurs, restore by reinstalling pve-manager with the following command:
``` bash
apt install --reinstall pve-manager
```
> ~~I don't know why reinstalling pve-manager causes an error in pvestatd.pm, so I commented out line 176 of pvestatd.pm~~
> Note on 2026.2.14: The pvestatd.pm error was caused by a historical issue from downgrading from PVE8 to PVE9. It is now completely normal.

Preview below:

![view](/images/view.png)