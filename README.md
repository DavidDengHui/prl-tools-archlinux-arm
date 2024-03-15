# Parallels Tools for Arch Linux ARM

![About Arch Linux](https://img2.covear.top/2024-02-29-20240229214413.png "About Arch Linux")
![2024-03-12-20240312203239](https://img2.covear.top/2024-03-12-20240312203239.png "2024-03-12-20240312203239")
![2024-03-15-20240315110612](https://img2.covear.top/2024-03-15-20240315110612.png "2024-03-15-20240315110612")

<p style="text-align: center;color: gray;">虚拟机系统信息</p>

这是一个为了适配 `Arch Linux ARM` 的 `Parallels Tools` 修改版本，相关运行环境如下：

| **序号** | **设备/软件**         | **版本**               | **备注**                                    |
|:------:|:-----------------:|:--------------------:|:-----------------------------------------:|
| 1      | Mac mini 2023     | Apple M2             | macOS Sonoma 14.3.1 (23D60)               |
| 2      | Parallels Desktop | 19.1.0 (54729)       | Parallels Tools  v19.1.0.54729            |
| 3      | Arch Linux ARM    | 6.7.6-1-aarch64-ARCH | [IMAGE](https://archboot.com/iso/aarch64/) |
| 4      | openSUSE Tumbleweed ARM  | 6.7.7-1-default | [IMAGE](https://download.opensuse.org/tumbleweed/iso/) |
| 5      | Fedora 39 ARM     | 6.7.9-200.fc39.aarch64 | [IMAGE](https://fedoraproject.org/workstation/download) |

- ❗️ps: 经测试，基本上所有 `6.7.X` 版本的内核都适用。

![About Parallels Desktop](https://img2.covear.top/2024-02-29-20240229215707.png "About Parallels Desktop")
<p style="text-align: center;color: gray;">Parallels Desktop 软件信息</p>

---

## 为什么要在虚拟机中安装 `Parallels Tools` ？
在虚拟机内部虽然不安装 Parallels Tools 也能正常使用系统，但是安装后能够显著改善虚拟机的操作效率、增强功能兼容性和提高整体用户体验，确保虚拟机环境更加贴近真实的硬件环境，大概会有以下方面的功能优化。
- 显示优化：
  - 自动调整分辨率适应宿主机窗口大小或实现全屏模式下的无缝切换。
  - 支持透明度效果和其他图形加速功能。
- 输入设备支持：
  - 优化鼠标指针在宿主机和虚拟机之间移动的无缝体验，消除鼠标捕捉等问题。
  - 提供更好的键盘响应，包括特殊键的支持。
- 文件共享：
  - 允许虚拟机与宿主机之间的文件共享，方便数据交换。
- 剪贴板共享：
  - 实现宿主机与虚拟机之间的文本、图片和其他内容的复制粘贴功能。
- 网络优化：
  - 改善虚拟网络适配器性能，使网络通信更为流畅。
- 同步时间：
  - 保持宿主机与虚拟机系统时间的一致性。
- 音频支持：
  - 提供高质量的音频重定向，让虚拟机中的声音能够正常播放到宿主机的扬声器。
- 打印服务：
  - 让虚拟机能够访问和使用宿主机的打印机资源。
- 快照和恢复功能：
  - 协助 Parallels Desktop 软件实现更高效的虚拟机快照和恢复机制。_(这对于 `ArchLinux` 来说很有用)_

---

## 为什么要修改官方提供的 `Parallels Tools` ？
运行环境如开头所介绍，在 `Arch Linux ARM` 虚拟机中按照官方说明安装时，提示有以下错误需要解决：

---

- [ ] **~~挂载的镜像无法直接安装，权限不足。~~**
	- ### 原生错误1：
  > - exec: ./installer/installer.aarch64: cannot execute: Permission denied
  ![2024-03-03-20240303004357](https://img2.covear.top/2024-03-03-20240303004357.png "2024-03-03-20240303004357")

  在挂载的镜像中直接运行 `install` 脚本有收到这个错误提示，尝试 `sudo` 运行和切换到 root 用户都无法正常安装，实测最简单的解决办法：把挂载的光驱中所有文件都拷贝出来，然后在本地文件夹中运行安装 `sudo ./install`，如果还是出现类似的权限提示，尝试在文件夹中运行 `chmod 777 ./ -R` 来将文件读写权限放开。

---

- [x] **部分依赖未安装，并且工具无法自动安装。**
  - ### 原生错误2：
  > - Error: An error occurred while installing the following packages: linux67-headers=6.7.6-1 make dkms 
  ![2024-03-03-20240303033533](https://img2.covear.top/2024-03-03-20240303033533.png "2024-03-03-20240303033533")

	第一次运行运行工具中的 `install` 脚本时，提示缺少以上依赖，尝试工具无法自动安装，应该是工具对 `Arch Linux` 的 `pacman` 包管理工具没有适配好，修改了 [`install`](./install) 脚本，在第43行中增加以下内容：
  ```shell
  [[ "$(uname -r)" == *"ARCH"* ]] && sudo pacman -S linux-aarch64-headers make dkms --noconfirm
  ```
  当然你也可以直接在终端中手动安装它们。
	```shell
	sudo pacman -S linux-aarch64-headers make dkms --noconfirm
	```
---

- [x] **工具无法正常编译。**
	- ### 原生错误3：
  > - modprobe: FATAL: Module prl_tg not found in directory /lib/modules/6.7.6-1-aarch64-ARCH
  ![2024-03-03-20240303035709](https://img2.covear.top/2024-03-03-20240303035709.png "2024-03-03-20240303035709")

  从日志中查询到了错误提示就很好解决了，浏览安装脚本，错误的源码来自 [`kmods/prl_mod.tar.gz`](./kmods/prl_mod.tar.gz) ，解压修改其中 `prl_fs/SharedFolders/Guest/Linux/prl_fs/inode.c` 源码，把 `i_atime` 替换为 `__i_atime` ，把 `i_mtime` 替换为 `__i_mtime` ，这里总共6处修改，重新打包即可。
  当然，你也可以手动运行以下 shell 脚本完成修改。
  ```shell
  #!/bin/bash

  mkdir -p ./kmods/prl_mod/
  tar -xzvf ./kmods/prl_mod.tar.gz -C ./kmods/prl_mod/
  mv ./kmods/prl_mod.tar.gz ./kmods/prl_mod.tar.gz.bak

  sed -i 's/i_atime/__i_atime/g' ./kmods/prl_mod/prl_fs/SharedFolders/Guest/Linux/prl_fs/inode.c
  sed -i 's/i_mtime/__i_mtime/g' ./kmods/prl_mod/prl_fs/SharedFolders/Guest/Linux/prl_fs/inode.c

  tar -czvf ./kmods/prl_mod.tar.gz ./kmods/prl_mod/*
  rm -rf ./kmods/prl_mod

  echo "All operations completed."
  ```

---

## 如何使用我修改好的 `Parallels Tools`？
本文提供两种主要方法快捷使用我修改好的工具包。

  - ### 使用方法1：
    - [x] 这个方法适用于虚拟机无法连接网络的情况，可以离线完成安装。
    - 1️⃣ 在本仓库的 [Releases](https://github.com/DavidDengHui/prl-tools-archlinux-arm/releases) 中查看下载打包好的 `.iso` 镜像文件。（❗️注：中国大陆地区可以查看位于 [Gitee](https://gitee.com/DavidDengHui/prl-tools-archlinux-arm/releases) 备份的仓库镜像）
    - 2️⃣ 在 Parallels Desktop 软件菜单栏 "`设备`" → "`CD/DVD`" → "`连接镜像`"，选择打开下载好的 `prl-tools-archlinux-arm.iso` 镜像文件。
    - 3️⃣ 在虚拟机中挂载镜像（挂载后的镜像标签名是 _`Parallels Tools for ALA`_），在终端中使用管理员权限运行镜像根目录中的安装脚本 `sudo ./install`，按照提示完成安装即可。

  - ### 使用方法2：
    - [ ] 这个方法适用于虚拟机可以正常上网，在虚拟机中直接完成安装。
    - 1️⃣ 在虚拟机中完整克隆本仓库 
      ```shell
      git clone https://github.com/DavidDengHui/prl-tools-archlinux-arm.git
      # Mirror of CHN: https://gitee.com/DavidDengHui/prl-tools-archlinux-arm.git
      ```
    - 2️⃣ 虚拟机终端中使用管理员权限运行仓库根目录中的安装脚本，按照提示完成安装即可。
      ```shell
      sudo ./prl-tools-archlinux-arm/install
      ```

---

## 修改版 `Parallels Tools` 工具包安装过程展示。

![2024-03-03-20240303030255](https://img2.covear.top/2024-03-03-20240303030255.png "2024-03-03-20240303030255")

![2024-03-03-20240303050549](https://img2.covear.top/2024-03-03-20240303050549.png "2024-03-03-20240303050549")

![2024-03-03-20240303033433](https://img2.covear.top/2024-03-03-20240303033433.png "2024-03-03-20240303033433")

![2024-03-03-20240303033457](https://img2.covear.top/2024-03-03-20240303033457.png "2024-03-03-20240303033457")

![2024-03-03-20240303034409](https://img2.covear.top/2024-03-03-20240303034409.png "2024-03-03-20240303034409")

![2024-03-03-20240303050703](https://img2.covear.top/2024-03-03-20240303050703.png "2024-03-03-20240303050703")

---

🎉🎉🎉🎉🎉🎉🎉🎉🎉🎉
:wink: :smile: Good luck～ :-) ;)