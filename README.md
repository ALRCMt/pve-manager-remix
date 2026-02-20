# PVE-Manager-remix

| 简体中文 | [English](/README_en.md) |

ALRCMt 合并的ProxmoxVE 节点概要页面的硬件监控信息

我本人只做了一些融合和防冲突的工作，概要内容完全是以下两位大佬的，感谢大佬的贡献  
https://github.com/MiKing233/PVE-Manager-Status   
https://github.com/a904055262/PVE-manager-status  

目前的脚本更加符合AMD使用（也许？）  
合并了a904055262大佬脚本的SATA与NVme硬盘相关内容，合并了MiKing233大佬的CPU频率功耗等相关内容  
因为我是小白，本着能用就绝不改，所以很冗余，不管了  
<img width="200" alt="image" src="./meme1.png" />

一键脚本，执行完毕后, 使用 Ctrl + F5 刷新
``` bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/ALRCMt/pve-manager-remix/refs/heads/main/merged-script.sh)"
```

如果出错通过下面的命令重新安装 pve-manager 来复原
``` bash
apt install --reinstall pve-manager
```
> ~~不知道为什么我重新安装pve-manager会导致pvestatd.pm报错，所以我设置了注释pvestatd.pm的176行~~   
> 2026.2.14注：是当初撤销PVE8升PVE9时的历史遗留问题导致pvestatd.pm报错，目前完全正常

预览如下  

![view](./view.png)


