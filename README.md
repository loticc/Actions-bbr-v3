# BBRv3 管理脚本

一个用于 Debian/Ubuntu VPS 的 BBRv3 内核安装与网络加速管理脚本。

脚本入口：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/byJoey/Actions-bbr-v3/main/install.sh)
```

首次运行后脚本会自动安装联网快捷命令，后续可直接运行：

```bash
b
```

快捷命令每次都会从 GitHub 拉取最新版脚本执行，不使用本地缓存脚本。

脚本会自动识别当前系统架构，从本仓库 GitHub Releases 下载匹配的 BBRv3 内核 `.deb` 包，并提供安装、指定版本安装、状态检查、加速模式切换和卸载功能。安装内核时可选择标准 BBRv3 或 BBRv3 Max 激进吞吐内核。

## 支持环境

| 项目 | 要求 |
| --- | --- |
| 最低支持系统 | Ubuntu 24.04+ / Debian 12+ |
| 推荐系统 | Ubuntu 24.04+ / Debian 12+ |
| 包管理器 | `apt-get` |
| 架构 | `x86_64` / `aarch64` |
| 引导方式 | 建议使用 GRUB |
| 使用场景 | VPS / 云服务器 / 独立服务器 |

不建议在树莓派、NanoPi 等依赖 U-Boot 或厂商定制内核链路的设备上使用。此类设备的内核安装和启动流程通常与通用 Debian/Ubuntu VPS 不一致。

Debian testing/unstable 如果缺少 `VERSION_ID`，脚本会按 `VERSION_CODENAME` 识别 `bookworm`、`trixie`、`forky` 和 `sid`。

| 系统 | 本项目内核安装 | 原因与边界 |
| --- | --- | --- |
| Debian 12+ / Ubuntu 24.04+ | 支持 `amd64` / `arm64` 的 `.deb` 包 | 需要能安装内核、生成 initramfs 并更新引导；云平台还要匹配磁盘和网卡驱动 |
| Alpine Linux | 暂不支持 | 尚无原生 `.apk` 产物，也未接入 `mkinitfs` 和 Alpine 的引导更新流程 |
| CentOS / CentOS Stream / Rocky / AlmaLinux | 暂不支持 | 尚无原生 `.rpm` 产物，也未接入 `dracut`、`kernel-install` 与 GRUB/BLS 流程 |
| Docker / LXC / OpenVZ 等共享宿主内核的容器 | 不支持在容器内更换内核 | 必须在可控制内核与引导的宿主机上安装 |

Alpine 与 CentOS 的支持请求分别跟踪于 [#32](https://github.com/byJoey/Actions-bbr-v3/issues/32) 和 [#40](https://github.com/byJoey/Actions-bbr-v3/issues/40)。它们需要原生打包、安装钩子和实际启动测试，不能通过安装 `dpkg` 或转换 `.deb` 包获得可靠支持。CentOS 7/8 已停止维护，也不能直接沿用本项目 Linux 7.x 的系统要求。

本项目当前内核主线为 Linux 7.x。安装内核时脚本会按最低支持系统拦截过旧环境，避免因用户态、initramfs 或引导链路过旧导致启动失败或 kernel panic。推荐系统是更稳妥的部署选择；旧系统仍可使用状态检查、网络调优、清空优化和卸载功能。

## 菜单功能

运行脚本后会进入交互菜单：

```text
1. 安装或更新 BBR v3 最新版
2. 指定版本安装
3. 检查 BBR v3 状态
4. 启用 BBR + FQ
5. 启用 BBR + FQ_CODEL
6. 启用 BBR + FQ_PIE
7. 启用 BBR + CAKE
8. 亚太机器 TCP 调优
9. 卸载 BBR 内核
10. BBR v3 智能带宽优化
11. 清空网络优化配置
12. BBR v3 疯批模式（极限测速挑战）
13. 禁用 IPv6
14. 恢复 IPv6
```

常用流程：

1. 选择 `1` 安装或更新 BBRv3 内核，并按提示选择标准版或 Max 极限版。
2. 按提示重启系统。
3. 重新运行脚本，选择 `3` 检查 BBRv3 状态。
4. 按需选择 `4` 到 `7` 设置队列算法。
5. 亚太线路机器可选择 `8` 写入 TCP 收发窗口与空闲慢启动调优。
6. 不确定线路参数时可选择 `10` 自动测速并按带宽档位计算 TCP 缓冲区。
7. 做自有链路极限测速挑战时可选择 `12` 写入激进冲速率参数。
8. 需要撤回调优时可选择 `11` 清空脚本写入的网络优化配置。

## 内核与 BBR 策略

本项目的构建目标是：

```text
BBRv3 补丁固定，内核自动跟随 kernel.org 最新 stable 更新。
```

也就是说，BBR 实现不会在自动构建时偷偷更新；自动更新的是 Linux stable 内核版本。构建流程会把仓库内固定的 BBRv3 patch 应用到最新 stable 内核上。

当前 patch 选择规则：

```text
linux-7.0.y -> patches/bbrv3-linux-7.0.patch
linux-7.1.y -> patches/bbrv3-linux-7.1.patch
linux-7.2.y -> patches/bbrv3-linux-7.2.patch
linux-7.3.y -> patches/bbrv3-linux-7.3.patch
```

同一个主线系列内的小版本更新会自动复用同一个 patch，例如 `7.2.10 -> 7.2.11`。如果新系列还没有对应 patch，脚本会尝试已有的最新补丁。精确应用失败时，会先试运行模糊匹配，确认能应用才继续；仍有冲突就停止构建。发生跨系列回退或模糊应用时，构建日志会提示维护者重新适配补丁。

## 安装最新版

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/byJoey/Actions-bbr-v3/main/install.sh)
```

首次运行后也可以直接输入：

```bash
b
```

该命令会联网拉取最新版脚本后运行。

选择：

```text
1. 安装或更新 BBR v3 最新版
```

脚本会：

- 检查系统是否为 Debian/Ubuntu。
- 检查架构是否为 `x86_64` 或 `aarch64`。
- 让用户选择标准 BBRv3 或 BBRv3 Max 激进吞吐内核。
- 从 GitHub Releases 获取当前架构和内核类型匹配的最新版本。
- 下载非 debug 的内核 `.deb` 包。
- 检查 DKMS、云平台驱动和启动文件，保留原有内核。
- 安装新内核，验证 initramfs 并更新引导配置。
- 提示是否重启。

如果遇到 GitHub API rate limit，可先设置 token：

```bash
export GITHUB_TOKEN=你的 GitHub Token
bash <(curl -fsSL https://raw.githubusercontent.com/byJoey/Actions-bbr-v3/main/install.sh)
```

## 指定版本安装

运行脚本后选择：

```text
2. 指定版本安装
```

脚本会先让用户选择标准 BBRv3 或 BBRv3 Max，再列出当前架构可用的 release tag，并按编号安装指定版本。

release tag 格式：

```text
x86_64-7.0.11
arm64-7.0.11
x86_64-7.0.11-max
arm64-7.0.11-max
```

其中不带 `-max` 的 tag 是标准 BBRv3 内核，带 `-max` 的 tag 是 BBRv3 Max 激进吞吐内核。Max 版会提高 Startup、ProbeBW 和 cwnd 策略的进攻性，但保留 BBRv3 的 loss、ECN、inflight 和 ProbeBW 反馈闭环，只适合自有链路吞吐测试，不建议日常生产使用。

## 检查 BBRv3 状态

运行脚本后选择：

```text
3. 检查 BBR v3 状态
```

脚本会检查：

- `tcp_bbr` 模块版本是否为 `3`。
- 当前 TCP 拥塞控制算法是否为 `bbr`。
- Dirty Frag 相关模块黑名单是否写入。

也可以手动检查：

```bash
uname -r
sysctl net.ipv4.tcp_congestion_control
sysctl net.core.default_qdisc
modinfo tcp_bbr 2>/dev/null | grep '^version:'
```

## Debian 安装后显示 Ubuntu

发行版和内核构建环境是两件事。安装本项目内核不会把 Debian 换成 Ubuntu。MobaXterm 等客户端可能根据内核构建信息判断系统；本项目在 Ubuntu 的 GitHub Actions 机器上编译，`/proc/version` 中可能出现 Ubuntu 的编译器版本。

以系统自己的发行版信息为准：

```bash
cat /etc/os-release
uname -r
uname -v
cat /proc/version
```

`/etc/os-release` 中的 `ID=debian` 表示当前用户态系统仍是 Debian；`uname -r` 显示正在运行的内核版本，`uname -v` 和 `/proc/version` 显示构建信息。客户端显示 Ubuntu 不代表安装错了系统，也不影响 BBRv3 的工作。编译器来源会如实保留，因此不能保证所有 SSH 客户端都按发行版识别。相关反馈见 [#38](https://github.com/byJoey/Actions-bbr-v3/issues/38)。

## 加速模式

脚本支持以下组合：

| 菜单 | 拥塞控制 | 队列算法 |
| --- | --- | --- |
| 4 | `bbr` | `fq` |
| 5 | `bbr` | `fq_codel` |
| 6 | `bbr` | `fq_pie` |
| 7 | `bbr` | `cake` |

选择后脚本会立即尝试应用配置，并询问是否永久写入：

```text
/etc/sysctl.d/99-joeyblog.conf
```

脚本不仅会写入 `net.core.default_qdisc`，还会尝试把当前默认路由出口网卡的 root qdisc 立即替换为所选算法，避免只对新建队列生效、当前网卡实际仍保持旧队列。

对于需要模块加载的队列算法，脚本会尝试加载对应 `sch_*` 模块，并在需要时写入：

```text
/etc/modules-load.d/joeyblog-qdisc.conf
```

## 亚太机器 TCP 调优

运行脚本后选择：

```text
8. 亚太机器 TCP 调优
```

脚本会立即应用并永久写入以下配置：

```text
net.ipv4.tcp_wmem = 4096 16384 12582912
net.ipv4.tcp_rmem = 4096 131072 33554432
net.ipv4.tcp_limit_output_bytes = 4194304
net.ipv4.tcp_slow_start_after_idle = 0
```

配置文件路径：

```text
/etc/sysctl.d/99-joeyblog.conf
```

## BBR v3 智能带宽优化

运行脚本后选择：

```text
10. BBR v3 智能带宽优化
```

脚本会优先安装并运行 Ookla 官方 `speedtest 1.2.0`，自动尝试附近测速服务器并获取上传/下载带宽；如果检测到 Python 版 `speedtest-cli`，会先自动移除并安装需要的 Ookla 官方版本。测速失败时会提示手动输入上传带宽。Speedtest 的测速节点延迟会被隐藏，不展示也不参与 RTT 计算，避免把测速节点延迟误当作真实业务线路延迟。

优化逻辑：

- 自动启用 `bbr` 拥塞控制和 `fq` 队列算法。
- 根据上传带宽和地区模式映射推荐 TCP buffer 档位。
- RTT 必须由用户手动输入，应填写真实链接延迟，使用 v2rayN 测出来的结果即可；不使用 Speedtest 测出来的 Ping。
- 用户手动选择亚太、美欧或手动 RTT + buffer 档位，不再按测速 RTT 自动判断。
- 亚太线路使用较保守的 buffer，美欧高延迟线路使用更大 buffer。
- 按机器内存设置 TCP buffer 上限，避免小内存 VPS 过度放大缓冲区。
- 同步写入 `net.core.rmem_max` / `net.core.wmem_max` / `tcp_rmem` / `tcp_wmem`。
- 保留 `tcp_limit_output_bytes = 4194304` 和 `tcp_slow_start_after_idle = 0`。

地区模式参考：

| 模式 | RTT 参考 |
| --- | --- |
| 亚太线路 | 通常小于 `100ms` |
| 美欧线路 | 通常 `150-300ms` |
| 手动 RTT | 按用户输入 RTT，并手动选择亚太或美欧 buffer 档位 |

配置同样写入：

```text
/etc/sysctl.d/99-joeyblog.conf
```

## BBR v3 疯批模式

运行脚本后选择：

```text
12. BBR v3 疯批模式（极限测速挑战）
```

该模式只面向自有链路的极限测速挑战，不建议日常使用。目标是尽量压榨单向吞吐和跑满带宽上限，会主动牺牲重传率、延迟抖动、排队延迟、连接稳定性、交互体验和流量公平性。

脚本会强制启用 `bbr` 拥塞控制和 `fq` 队列算法，并立即尝试替换当前默认路由出口网卡的 root qdisc。

写入参数：

```text
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.core.rmem_max = 1073741824
net.core.wmem_max = 1073741824
net.core.optmem_max = 1073741824
net.core.netdev_max_backlog = 1000000
net.core.somaxconn = 65535
net.ipv4.tcp_wmem = 4096 1048576 1073741824
net.ipv4.tcp_rmem = 4096 1048576 1073741824
net.ipv4.tcp_limit_output_bytes = 268435456
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_notsent_lowat = 4294967295
net.ipv4.tcp_autocorking = 0
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_moderate_rcvbuf = 1
net.ipv4.tcp_ecn = 0
```

脚本还会把当前默认出口网卡的运行态 `txqueuelen` 拉高到 `100000`，让测速时本机发送队列更激进。该项不是 sysctl 参数，不会写入 `/etc/sysctl.d/99-joeyblog.conf`。

其中核心参数应用失败会中止；不同内核可能不支持部分附加参数，脚本会尽量写入，失败的附加项不会阻断整个模式。

## 清空网络优化配置

运行脚本后选择：

```text
11. 清空网络优化配置
```

脚本会清理本项目写入的网络优化持久配置：

- `net.core.default_qdisc`
- `net.ipv4.tcp_congestion_control`
- `net.core.rmem_max` / `net.core.wmem_max` / `net.core.optmem_max`
- `net.core.netdev_max_backlog` / `net.core.somaxconn`
- `net.ipv4.tcp_rmem` / `net.ipv4.tcp_wmem`
- `net.ipv4.tcp_limit_output_bytes`
- `net.ipv4.tcp_slow_start_after_idle`
- `net.ipv4.tcp_notsent_lowat`
- `net.ipv4.tcp_autocorking`
- `net.ipv4.tcp_no_metrics_save`
- `net.ipv4.tcp_mtu_probing`
- `net.ipv4.tcp_fastopen`
- `net.ipv4.tcp_window_scaling`
- `net.ipv4.tcp_moderate_rcvbuf`
- `net.ipv4.tcp_ecn`

同时删除：

```text
/etc/modules-load.d/joeyblog-qdisc.conf
```

该功能只清空网络优化配置，不卸载 BBR 内核，也不移除 Dirty Frag 安全缓解规则或 IPv6 开关配置。当前运行态参数可能需要重启后完全恢复为系统默认值。

## 禁用与恢复 IPv6

菜单 `13` 会在确认后禁用当前接口和以后新建接口的 IPv6，配置独立保存到：

```text
/etc/sysctl.d/99-joeyblog-ipv6.conf
```

当前 SSH 连接使用 IPv6，或机器没有 IPv4 默认路由时，脚本会拒绝禁用，避免直接切断管理连接。需要 IPv6 的服务和客户端也会受影响，执行前请确认用途。

首次禁用前，脚本会把 `all`、`default` 和当前各接口的 `disable_ipv6` 原值保存到 `/var/lib/joeyblog/ipv6-before-disable`，重复禁用不会覆盖这份快照。

菜单 `14` 撤回本项目的 IPv6 配置，先恢复 `all`、`default`，再逐接口恢复原值，最后重新加载系统的其他 sysctl 规则。已消失的接口跳过，新接口沿用原来的 `default` 设置。原有或其他持久规则仍禁用 IPv6 的接口会单独列出，脚本不会删除那些规则。恢复失败时保留快照供重试，成功后删除。菜单 `11` 清空网络优化时会保留这个独立开关。

## 安全缓解

脚本启动时会写入 Dirty Frag 风险面收敛规则：

```text
/etc/modprobe.d/99-joeyblog-security.conf
```

包含：

- `esp4` / `esp6` / `rxrpc` 黑名单，用于收敛 Dirty Frag 相关风险面。

如果模块当前已加载，脚本会尝试卸载；如果模块被占用，则黑名单会在重启后生效。

CVE-2026-31431 对应的 AEAD userspace 接口在新构建内核中由内核配置侧收敛：

```text
# CONFIG_CRYPTO_USER_API_AEAD is not set
```

因此安装脚本不再额外写入 `algif_aead` 黑名单。
如果旧版本脚本已经写入过该黑名单，新脚本只会在当前运行内核确认关闭 `CONFIG_CRYPTO_USER_API_AEAD` 后移除它。

## CVE-2026-31431 检测

仅检测，不利用：

```bash
command -v python3 >/dev/null 2>&1 || (sudo apt update && sudo apt install -y python3)
curl -fsSL -o cve_2026_31431_detector.py https://raw.githubusercontent.com/byJoey/Actions-bbr-v3/main/cve_2026_31431_detector.py
chmod +x cve_2026_31431_detector.py
sudo python3 cve_2026_31431_detector.py
```

## 内核包来源

`.deb` 内核包由 GitHub Actions 构建并发布到本仓库 Releases。

构建流程会：

- 读取 kernel.org 最新 stable 版本。
- 从官方版本标签解析并固定源码提交，核对 Makefile 中的实际版本。
- 应用仓库内固定 BBRv3 patch。
- 强制默认启用 BBR 和 fq。
- 关闭 debug info。
- 拒绝发布 `*-dbg*.deb` / `*-dbgsym*.deb`。

构建不会自动更新 BBR patch 本身，也不会把另一个版本的源码改成预期版本号发布。构建用户名与主机名固定为 `byjoey@actions-bbr-v3`；编译器版本保留真实来源。

## 安装失败与云平台恢复

### OCI ARM64：DKMS 模块编译失败

[#37](https://github.com/byJoey/Actions-bbr-v3/issues/37) 中的实际失败项是第三方 `mimic/0.7.1` 的 DKMS 构建，随后 `/etc/kernel/postinst.d/dkms` 返回错误，导致新内核包停在 `half-configured`。这份日志不能证明 OCI ARM64 本身不受支持。

出现 `dkms autoinstall ... failed` 时，先保留当前可启动内核，查看具体失败模块：

```bash
uname -r
dkms status
sudo dpkg --audit
sudo tail -n 120 /var/lib/dkms/mimic/0.7.1/build/make.log
```

最后一条路径对应 Issue 中的版本；其他模块或版本以错误日志给出的路径为准。按日志更新模块或确认它支持目标内核；只有确认模块用途且不再需要它时，才考虑移除。不要为了让安装通过而直接删掉 DKMS 钩子或清空全部模块。

安装脚本会提前拦截已注册的 `mimic/0.7.1`，防止再次进入这条已知失败流程。它不会自动移除模块，也不会绕过 DKMS 检查。其他第三方模块仍需核实与目标内核的兼容性。

解决模块构建问题后，再执行 `sudo dpkg --configure -a`。只有包配置、initramfs 生成和引导更新全部成功，才重启。`kernel package ... is not supported` 可能来自 Ubuntu 的 DKMS 错误上报组件，根因仍要看模块自己的 `make.log`。

### Azure：重启后无法连接

[#39](https://github.com/byJoey/Actions-bbr-v3/issues/39) 的配置对比已指出旧构建缺少 Hyper-V 驱动，可能导致系统找不到根磁盘或网卡。SSH 防火墙放行无法修复这个启动阶段的问题。

新构建会强制检查 Hyper-V 磁盘、网卡、PCI 和 NVMe 支持；安装脚本也会在识别到 Hyper-V 环境时检查下载包的驱动配置。缺少启动驱动就中止安装，不会继续提示重启。已经下载或安装的历史包不会因此自动修好，请使用修复后重新构建的产物。

先通过 Azure 串行控制台、启动诊断或救援环境，在 GRUB 的高级选项中选择原来的发行版内核。进入系统后运行 `uname -r`，确认已经回到可用内核，再修复或卸载故障版本。没有控制台入口时，按云平台文档把系统盘挂载到救援虚拟机处理。

可以查看目标内核的配置；下面命令检查的是当前运行内核，检查其他版本时替换文件名：

```bash
grep -E '^CONFIG_(HYPERV|HYPERV_STORAGE|HYPERV_NET|PCI_HYPERV|SCSI|BLK_DEV_SD|NVME_CORE|BLK_DEV_NVME)=' "/boot/config-$(uname -r)"
```

磁盘和网卡驱动必须可用。配置为 `y` 的驱动已编入内核，不会以 `.ko` 文件出现在 initramfs 中；配置为 `m` 的启动必需驱动则应被打进目标内核的 initramfs。不能仅凭 `lsinitramfs` 没找到模块就判断驱动缺失。

安装新内核时保留发行版原有内核，确认新内核启动与联网正常后再清理。仅重启服务、调整安全组或重新部署同一故障内核，无法补齐缺失的驱动。

## 卸载

运行脚本后选择：

```text
9. 卸载 BBR 内核
```

脚本会卸载由本项目安装的 `joeyblog` 内核包，并更新引导配置。卸载后建议重启。

## 反馈

博客：

[JoeyBlog](https://joeyblog.net)

反馈群组：

[Telegram Feedback Group](https://t.me/+ft-zI76oovgwNmRh)

## 免责声明

内核升级有风险。安装前建议确认 VPS 控制台、救援模式或旧内核启动项可用。使用本项目构建或安装的内核造成的系统启动失败、网络异常或数据损失，由使用者自行承担。

## Star History

<a href="https://star-history.dera.page/#byJoey/Actions-bbr-v3&Timeline">
 <picture>
   <source media="(prefers-color-scheme: dark)" srcset="https://star-history.dera.page/svg?repos=byJoey/Actions-bbr-v3&type=Timeline&theme=dark" />
   <source media="(prefers-color-scheme: light)" srcset="https://star-history.dera.page/svg?repos=byJoey/Actions-bbr-v3&type=Timeline" />
   <img alt="Star History Chart" src="https://star-history.dera.page/svg?repos=byJoey/Actions-bbr-v3&type=Timeline" />
 </picture>
</a>
