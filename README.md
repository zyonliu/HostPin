# HostPin 定址

**原生 SwiftUI macOS Hosts 工具。** 按规则查找域名和候选 IP，检测连接质量，自动优化或批量处理，并通过受控后台助手写入系统 Hosts。

当前版本：**1.0.0 Local PKG** · 开发署名：**ZyonLiu**

[下载安装包](https://github.com/zyonliu/HostPin/releases/latest) · [v1.0.0 发布说明与附件](https://github.com/zyonliu/HostPin/releases/tag/v1.0.0)

## 系统要求

| 项目 | 要求 |
| --- | --- |
| 系统 | macOS 14 或更新版本 |
| 架构 | Apple Silicon（arm64）和 Intel（x86_64），Local PKG 同时包含两种架构 |
| 玻璃效果 | macOS 26 及以上使用系统 Liquid Glass；macOS 14–25 使用材质回退 |
| 写入权限 | Local PKG 安装时需要管理员授权，后续使用由助手处理写入 |
| 开发环境 | Xcode 26 或更新版本，包含相应 macOS SDK |
| 当前验证环境 | macOS 27、Xcode 27.2 / macOS SDK 27.2；旧系统兼容路径尚未在旧设备实测 |

## 安装与升级

1. 从 [Releases](https://github.com/zyonliu/HostPin/releases/latest) 下载 `HostPin-1.0.0-Local.pkg`。
2. 退出正在运行的 HostPin，运行完整 PKG，按 macOS 安装器提示完成管理员授权。
3. 打开“应用程序”中的 HostPin。助手连接成功后，窗口底部显示“Hosts 写入已启用”。
4. 此后管理员账户正常打开应用、保存 Hosts、应用优化结果时，无需反复输入密码。安装或升级完整 PKG 时，macOS 仍会请求安装授权。

应用与助手需要成套升级。完整 PKG 会同时安装二者及配套指纹，处理旧服务的停用状态并检查注册结果。

**Local PKG 的签名说明：** 此发布使用本地 ad-hoc 签名和 hardened runtime，尚未使用 Developer ID 签名或经过 Apple 公证。macOS 对下载包的检查可能影响安装体验。请核对下载来源；需要自行构建时，参见下方构建说明。不要为安装本应用关闭系统整体安全保护。

## 功能与操作

### 规则库

- 分类浏览规则，按规则名、英文名或域名搜索。
- 直接点击搜索框旁的刷新图标更新在线规则，状态文字显示下载、备用源、校验及结果。
- 查看候选 IP、延迟、下载速度和 TLS 验证结果。
- 独立提供检测延迟、下载测速、自动优化、清除当前映射、复制映射、DNS 查询和应用选中地址。
- 使用右键分类菜单切换规则，侧栏会展开并定位选中的规则；规则也可加入批量队列。
- 拖动侧栏分隔线调整宽度。自动优化运行时原位切换为停止按钮。

**自动优化范围是当前规则的整张候选列表，和预选 IP 无关。** 主要过程为：

1. 并行检测候选地址的延迟，并按延迟排序。
2. 规则要求证书验证时，对最快的最多 20 个地址执行 TLS 验证。
3. 存在下载样本时，对最多 10 个合格地址测速，每个地址的采样上限为 5 秒。
4. 优先选下载结果最好的地址；下载测速全部失败或没有样本时，回退到延迟最低的合格项。
5. 助手可用时应用选出的映射；助手未启用时展示变更预览。

HostPin 的 TLS 验证采用系统信任链和主机名校验。原版的证书匹配方式不同，个别规则可能获得不同的候选结果。测速结果也会受到网络、线路和测试时刻影响。

“应用选中”针对选中的地址；未通过所需 TLS 验证时会先提示确认。“DNS 查询”用查询结果替换当前候选列表。

### 批量处理

- 通过添加规则或右键分类菜单建立待处理队列。
- 支持全选、反选、移除勾选和清空列表。
- 保存默认队列，或新建、保存和删除命名分组。
- 并行进行筛选与下载两个阶段，逐条显示进度、推荐地址和结果。
- 提供开始、停止和应用结果操作；正常完成且助手可用时会应用成功的结果。
- 在设置中分别控制筛选阶段与下载阶段的并发数。

### Hosts 编辑

- 查看并编辑系统 Hosts，提供行号、查找、上一处/下一处匹配、替换和全部替换。
- 提供重新加载、外部编辑器和保存操作。
- 首次进入和从其他标签返回时读取最新文件，状态文字前显示统一刷新反馈。
- 自动刷新保护未保存草稿；手动重新加载会先确认是否舍弃草稿。
- 切换标签后保留草稿及独立的撤销记录。切回编辑页可直接使用 `⌘Z` 撤销、`⌘⇧Z` 重做。
- 重新加载不同的磁盘内容时清除过期撤销记录，避免将旧字符范围用于新文件。撤销历史最多保留 100 组。
- 有写入权限时保存草稿；助手未启用时先展示预览。

### 设置

| 分类 | 内容 |
| --- | --- |
| 界面设置 | 简体中文 / English、跟随系统 / 浅色 / 深色、规则图标大小 |
| 性能设置 | TCP / ICMP 延迟检测、两个批量阶段的并发数、DNS 服务器 |
| 规则来源 | 验证并切换 HTTPS 来源、刷新、查看来源与快照时间、导入和导出 |
| 备份设置 | 写入前自动备份、保留数量、打开目录、预览还原 |
| 高级设置 | 清除工具管理的 Hosts 映射、重置设置 |
| 关于 | 当前版本、HostPin 署名、原版及作者鸣谢 |

设置会绑定对应界面和实际执行逻辑。界面采用暖色强调色，正文、表格和编辑区保留清晰底色；红黄绿窗口按钮使用系统自身外观。

## 在线规则、迁址与本地快照

默认在线来源是原作者维护的规则文件及备用来源，具体地址集中在 `Sources/HostPinCore/Rules.swift`。应用启动和手动刷新时都会尝试更新，正常 HTTPS 重定向会被跟随。

上游改用新地址、又未提供重定向时：

1. 打开“设置 → 规则来源”。
2. 填写兼容 UsbEAm 格式的 **HTTPS 规则文件直链**。
3. 点击“验证并切换”。下载、解析、快照保存全部成功后才保存新来源。

切换后会使用新来源；更新失败时保留最后一份有效快照。清空地址再验证切换可恢复默认来源。也可以导出规则快照，或导入兼容的 UTF-8 规则文件。

出现“使用本地快照”表示本次在线更新没有成功，已有规则仍可使用。先检查网络或代理、来源是否可访问，再重新刷新。快照保留最后一次有效内容，不会自行获得停服后的新规则。应用不会根据原作者的新软件版本自动推断未公布的新规则地址。

## 写入、备份与安全边界

| 用途 | 位置或标识 |
| --- | --- |
| 实际系统 Hosts | `/private/etc/hosts`（通常也可经 `/etc/hosts` 访问） |
| 编辑页路径标签 | `~/etc/hosts`，这是界面标签；实际操作目标为上面的系统路径 |
| 本地规则快照 | `~/Library/Application Support/HostPin/rules.ini` |
| Hosts 备份目录 | `/private/var/db/HostPin-Backups` |
| 备份文件 | `hosts-<UUID>` |
| Local PKG 写入助手 | `/Library/PrivilegedHelperTools/com.hostpin.app.local-writer` |
| Local PKG 服务配置 | `/Library/LaunchDaemons/com.hostpin.app.local-writer.plist` |
| HostPin 管理的映射 | `# HostPin:<规则标识>`；兼容原版 `#UHE_` / `#UHE_数字` 标记 |

- 主应用负责交互、规则获取和测速，特权助手固定写入系统 Hosts。
- Local PKG 的两端通过各架构 CDHash 相互校验；助手另检查管理员账户身份。
- 写入会校验目标文件的类型、所有者、链接数量与权限，并比较预览时的旧内容；内容已被其他程序改变时拒绝覆盖。
- 启用备份后先保存旧内容，再通过同目录临时文件和原子替换提交。备份保留数限制在 1–100。
- 清除操作识别工具管理的映射；遇到冲突的手工映射时提示在编辑器中处理。
- Hosts 的读取、编辑和写入上限为 1 MiB；规则文件上限为 8 MiB，展开后的规则内容有总量限制。
- 规则通过 HTTPS 流式接收，拒绝降级至 HTTP 的重定向。下载样本可依照上游规则使用 HTTP 或 HTTPS；样本只用于测速。
- 外部网络命令使用固定可执行路径和独立参数；下载的规则及采样内容不会作为程序执行。

## 从源码构建

工程使用 Swift Package Manager，没有第三方运行时依赖。先安装 Xcode 并让 `xcode-select` 指向所用版本，随后在终端确认：

```sh
xcodebuild -version
xcrun --show-sdk-version
swift --version
```

获取代码：

```sh
git clone https://github.com/zyonliu/HostPin.git
cd HostPin
chmod +x Packaging/build-app.sh Packaging/build-local-installer.sh \
  Packaging/local-installer/preinstall Packaging/local-installer/postinstall
```

网页上传的源码未保留脚本执行位，构建前先执行上面的 `chmod`，包括 PKG 的安装钩子；从源码 ZIP 解压后也执行同一步骤。

### 测试

```sh
swift test -Xswiftc -warnings-as-errors
```

当前包含 21 项测试：编辑器生命周期与撤销/重做、规则解析、Hosts 写入和备份、网络探测，以及输入与权限边界。一项在线规则兼容性测试需要本地规则快照，未设置时会跳过：

```sh
HOSTPIN_TEST_RULES="$HOME/Library/Application Support/HostPin/rules.ini" \
  swift test -Xswiftc -warnings-as-errors
```

测试使用临时文件和本机回环服务，不写入实际系统 Hosts。

### 构建预览应用

```sh
./Packaging/build-app.sh
```

产物为 `dist/HostPin.app`。默认是 ad-hoc 预览构建，不包含可启用的系统写入助手，适合检查界面、搜索与测速。

### 构建完整 Local PKG

```sh
./Packaging/build-local-installer.sh
```

产物为 `dist/HostPin-1.0.0-Local.pkg`，包含 Universal 应用、特权助手及服务配置。脚本会同步生成两端指纹并验证签名，保持最低部署版本为 macOS 14，使用当前 SDK 的链接元数据。

版本号来自 `Packaging/Info.plist`：`CFBundleShortVersionString` 为用户可见版本，`CFBundleVersion` 为递增构建号。

### Developer ID 应用构建

持有 Apple 签名身份时可执行：

```sh
HOSTPIN_SIGN_IDENTITY='Developer ID Application: Your Name (TEAMID)' \
  ./Packaging/build-app.sh
```

此路线将助手放入应用包，并通过 `SMAppService` 注册。把签名应用安装到“应用程序”，首次启用写入时按 macOS 提示批准后台服务。Developer ID 应用构建与上述 Local PKG 的助手部署方式不同；公开分发还需要相应公证流程。

## 排查问题

**助手没有启用，或升级后无法连接**

退出应用，重新安装同一版本的完整 PKG，再打开应用。可用以下只读命令查看注册情况：

```sh
pkgutil --pkg-info com.hostpin.app.local-installer
launchctl print system/com.hostpin.app.local-writer
```

安装失败时查看 `/var/log/install.log`。请先刷新 Hosts 确认实际文件内容，再决定是否重试未确认结果的写入。

**保存时提示文件已更改**

系统 Hosts 已经被其他程序修改。重新加载当前文件，处理草稿差异，再保存。

**某条规则没有可用地址，或与原版选出的 IP 不同**

检查当前网络、延迟模式和规则的下载样本。系统 TLS 校验、网络状态及测试时刻都可能影响结果。可通过候选列表、单独测速和 DNS 查询检查具体地址。

## 卸载

如需先清理工具写入的映射，可在应用的高级设置中预览清除，或从备份还原。退出 HostPin 后，卸载 Local PKG 的服务和助手：

```sh
sudo launchctl bootout system/com.hostpin.app.local-writer
sudo rm /Library/LaunchDaemons/com.hostpin.app.local-writer.plist
sudo rm /Library/PrivilegedHelperTools/com.hostpin.app.local-writer
```

然后在 Finder 删除 `/Applications/HostPin.app`。上述命令保留系统 Hosts、备份和用户偏好；服务未加载时，第一条命令可能提示找不到服务。

## 工程结构

```text
Package.swift
Sources/
  HostPin/              SwiftUI 界面、AppKit 编辑器、设置与写入客户端
  HostPinCore/          规则解析、下载、测速、Hosts 操作及助手协议
  HostPinHelper/        特权写入服务
Tests/
  HostPinCoreTests/     核心功能及输入安全测试
  HostPinEditorTests/   编辑器生命周期、撤销命令和菜单测试
Packaging/             图标、Info.plist、构建及安装脚本
```

安装包在 GitHub Release 附件中提供；`dist/` 和构建缓存由 `.gitignore` 排除。

## 作者与鸣谢

- **HostPin 定址开发：ZyonLiu**
- **参考原作：UsbEAm Hosts Editor 5.0.1**
- **原作者：羽翼城 | Dogfight360**
- [原版发布页](https://www.dogfight360.com/blog/18627/)

感谢原作者开发 UsbEAm Hosts Editor、维护在线规则，并提供相关使用思路。HostPin 是独立的原生 macOS 实现，上游规则及原版应用的相关权利归原作者所有。

本仓库当前未指定开源许可证。
