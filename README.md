# PVE-Manager-remix
ALRCMt 合并的超级屎中屎ProxmoxVE 节点概要页面扩展的硬件监控信息

<img width="200" alt="image" src="./meme1.png" />

我本人几乎没有做任何贡献，只是合并了两个大佬的脚本  
原库1：https://github.com/MiKing233/PVE-Manager-Status  
原库2：https://github.com/a904055262/PVE-manager-status  

目前的脚本更加符合AMD使用（也许？反正我还行）  
去除了a904055262大佬脚本的CPU频率相关内容，去除了MiKing233大佬的SATA与NVme硬盘相关内容  
其它内容相融合，因为我是小白，本着能用就绝不改，所以代码很冗余，不管了

一键脚本，执行完毕后, 使用 Ctrl + F5 刷新
``` bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/ALRCMt/pve-manager-remix/refs/heads/main/merged-script.sh)"
```

如果出错通过下面的命令重新安装 pve-manager 来复原
``` bash
apt install --reinstall pve-manager
```

预览如下  

![view](./view.png)


