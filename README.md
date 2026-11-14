# IOSJB 研究终端

IOSJB 是一个运行在 iPhone 上的 **CVE-2026-112514** 研究工具。该漏洞是 XNU
Socket 缓冲区中的 Use-After-Free，Apple 已在 iOS 27.2 中修复。

当前版本：**v0.1.1**

> 这不是完整越狱。目前只能触发竞态，并检测数据是否被写入已经释放后重新分配的
> Socket。尚未实现受控内核读写、SPTM/TXM/PAC 绕过或 Bootstrap。

## 已实现功能

- 支持 iOS 16 及以上版本的 SwiftUI App。
- 使用常驻发送线程和条件变量门闸的低 CPU 精确竞态。
- Peer-Delivery 检测：喷射 Socket 从不主动发送，因此其 peer 收到的数据只能来自
  已经关闭的发送者。
- 独立的 832 字节 OOL Mach 消息 Zone 回收探针。
- 可随时停止，并带有限速，减少 Watchdog 压力。
- 运行日志自动写入 `Documents/IOSJB.log`，支持复制和文件分享。
- GitHub Actions 自动编译 unsigned IPA。

## 目标设备

| 项目 | 内容 |
|---|---|
| 主要目标 | iPhone 14 Pro Max（`iPhone15,3`，A16） |
| 受影响系统 | iOS 27.0、27.0.1 |
| 已修复系统 | iOS 27.2 及更高版本 |
| 特殊权限 | 除正常侧载签名外无额外权限 |
| 内核读写 | 尚未实现 |

公开的硬件证据来自另一台 arm64e 设备。A16 上的命中率必须单独测量。请只在
你拥有并获授权测试的设备上运行。

## 编译

推送到 `main` 或手动触发 GitHub Actions 后会生成 unsigned IPA：

```text
Actions -> Build unsigned IPA -> Artifacts -> IOSJB-unsigned
```

在安装了完整 Xcode 的 Mac 上本地编译：

```sh
chmod +x scripts/build_ipa.sh
./scripts/build_ipa.sh
```

输出文件：

```text
dist/IOSJB-unsigned.ipa
dist/IOSJB-unsigned.ipa.sha256
```

CI 产物默认不签名。请使用你自己的开发者证书或常用侧载工具重签，也可以在 Xcode
中选择自己的 Team 后编译。

Host 侧 Smoke Test：

```sh
mkdir -p build
xcrun --sdk macosx clang -O2 -Wall -Wextra -Werror \
  Tests/host_smoke.c Sources/SocketUAF.c -o build/host-smoke
./build/host-smoke
```

## 测试步骤

1. 在目标 iPhone 上安装已签名的 App。
2. 确认系统为 iOS 27.0 或 27.0.1。
3. 保持 App 在前台。
4. 先运行一次 **Zone 回收探针**，确认 App 和分配器路径正常。
5. 切换到 **精确 UAF 检测**，先使用默认参数。
6. 出现命中后建议停止，并保存日志。

> 竞态可能破坏正在使用的内核对象并导致设备重启。运行前请保存工作。

日志会自动写入：

```text
文件 App > 我的 iPhone > IOSJB > IOSJB.log
```

也可以直接点击日志卡片中的 **分享** 或 **复制**。

## 模式说明

### 精确 UAF 检测

执行 close 与 send 的竞态，并检查陈旧发送者的数据是否到达一个从未发送过的
Socket。命中只能证明发生了 stale kernel write，不代表已经获得受控内核读写。

### Zone 回收探针

分配并释放 Socket 对象，喷射 832 字节 OOL Mach 消息，然后检查新建 Socket 的字段
是否出现标记值。这是一个探索性分配器测试，本身不会触发 UAF 竞态。

## 当前限制

- 尚无公开证据证明同一竞态在 A16 上能够达到受控原语。
- 没有 KASLR 或内核堆地址泄漏。
- 没有稳定的攻击者数据替换 `struct socket` 方案。
- 没有 SPTM/TXM/PAC 绕过。
- 没有 Rootless Bootstrap、Launchd Hook 或 Tweak 注入。

## 研究文档

- [CVE-2026-112514 研究记录](docs/CVE-2026-112514.md)
- [设备测试说明](docs/TESTING.md)
- [来源与边界](docs/SOURCES.md)

## 许可证

MIT，详见 [LICENSE](LICENSE)。
