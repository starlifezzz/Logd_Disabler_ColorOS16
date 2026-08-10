# ColorOS 16 终极优化模块

> **专为一加ACE5等ColorOS 16设备打造的KernelSU系统优化模块**

![KernelSU Compatible](https://img.shields.io/badge/KernelSU-Compatible-green?logo=android)
![ColorOS 16](https://img.shields.io/badge/ColorOS-16-blue)

## 🎯 核心特性

### ✨ **UI控制界面（KernelSU 0.7.0+）**
- **内置图形化设置界面**：在KernelSU管理器中直接开关各项功能
- **无需编辑配置文件**：通过直观的UI界面控制所有优化选项
- **本地框架渲染**：WebUI 基于 Vue 3 + mdui 2（全部资源随模块本地打包，不依赖 CDN/在线组件库）
- **配置实时持久化**：UI 设置写入 `config.json`（`/data/adb/Logd_Disabler_ColorOS16/config.json`），重启后由脚本读取生效

### 🔧 **配置机制说明（v2.0）**
- **唯一配置源**：`/data/adb/Logd_Disabler_ColorOS16/config.json`（模块外数据目录，升级模块不覆盖配置）
- **WebUI 唯一写入者**：开关状态通过原子写（base64 + 临时文件 + mv）持久化，服务脚本只读执行
- **UI 修改即时生效**：开关状态即写即存，重启设备后由 service.sh 执行实际优化
- **双向操作**：每个功能都支持"开启优化 / 关闭恢复"
- **v1.x 自动迁移**：首次运行 service.sh 会从旧 `persist.sys.coloros16_optimize_gui.*` 属性一次性迁移，升级不丢配置

### 🔒 **安全可靠**
- **Systemless 设计**：所有优化基于 mount bind / pm 命令，卸载模块后大部分修改自动复原
- **多阶段执行**：post-fs-data（挂载覆盖 + SELinux 规则）、service（包管理 + 参数）、boot-completed（健康校验）
- **完整日志**：操作日志记录在 `/data/adb/logd_disabler/*.log`

### ⚡ **深度优化**
- 彻底禁用logd日志系统
- 完全阻断OTA自动更新
- 屏蔽系统广告与数据收集
- 禁用冗余后台服务
- 内核级内存/IO优化

## 📋 功能列表

| 功能 | 描述 | 默认状态 |
|------|------|----------|
| **日志系统优化** | 彻底禁用logd，永久封死复活 | ✅ 启用 |
| **OTA更新阻断** | 禁用所有系统更新组件 | ✅ 启用 |
| **开发者选项锁定** | 防止系统重置开发者设置 | ✅ 启用 |
| **广告与数据收集屏蔽** | 关闭系统广告和用户数据统计 | ✅ 启用 |
| **内存/IO轻量优化** | 内核参数调优，提升性能 | ✅ 启用 |
| **健康与运动服务** | 禁用健康相关后台服务 | ❌ 禁用 |
| **流量监控与网络服务** | 减少后台网络活动 | ❌ 禁用 |
| **锁屏杂志与壁纸服务** | 节省存储和网络资源 | ❌ 禁用 |
| **游戏空间与性能监控** | 减少系统负载 | ❌ 禁用 |
| **钱包与支付服务** | 禁用NFC支付相关服务 | ❌ 禁用 |
| **备份与云服务** | 禁用自动备份功能 | ❌ 禁用 |
| **额外内核优化** | 更深入的内核参数调整 | ✅ 启用 |
| **进程查杀优化** | 杀死冗余后台进程 | ✅ 启用 |
| **系统属性开关** | 锁定各种系统服务开关 | ✅ 启用 |

## 🎮 UI控制界面使用

### 前提条件
- **KernelSU版本**: 0.7.0 或更高版本
- **Android版本**: Android 10+

### 使用方法
1. **安装模块**并重启设备
2. 打开 **KernelSU管理器**
3. 进入 **"模块"** 页面
4. 点击 **"ColorOS 16 终极优化模块"**
5. 在弹出的UI界面中**直接开关各项功能**
6. **重启设备**使设置生效

### UI界面分组
- **核心优化**: 日志禁用、OTA阻断、开发者选项锁定
- **隐私与广告**: 系统广告和数据收集屏蔽  
- **性能优化**: 内存/IO优化、内核调优、进程查杀
- **可选服务**: 健康服务、网络监控、锁屏杂志等

## 📂 配置管理

### 配置存储机制（v2.0）
- **配置源**：`/data/adb/Logd_Disabler_ColorOS16/config.json`（如 `disable_logd`、`block_ota` 等键）
- **写入方式**：WebUI 开关修改后原子写入（base64 + 临时文件 + mv），模块外目录不受升级影响
- **读取时机**：post-fs-data（挂载覆盖）和 service（包管理 + 参数）阶段读取 config.json 决定是否执行优化
- **兼容性**：v1.x 的 `persist.sys.coloros16_optimize_gui.*` 属性在首次开机时自动迁移，无需手动处理

### 手动修改配置（高级用户）
```bash
# 通过 adb 查看当前配置
adb shell
su
cat /data/adb/Logd_Disabler_ColorOS16/config.json

# 手动修改（示例：启用日志禁用），修改后需重启生效
sed -i 's/"disable_logd": false/"disable_logd": true/' /data/adb/Logd_Disabler_ColorOS16/config.json
reboot
```

### 验证状态
```bash
# 执行验证脚本（v2.0 自动读取 config.json）
su
sh /data/adb/modules/Logd_Disabler_ColorOS16/verify_status.sh
```

## 🚀 快速开始

### 方法1: 使用UI界面（推荐）
1. 安装 `Logd_Disabler_ColorOS16.zip`
2. 重启设备
3. 在KernelSU管理器中点击模块名称
4. 通过UI界面调整设置
5. 再次重启设备

### 方法2: 手动修改配置
```bash
# 查看当前所有配置
adb shell
su
cat /data/adb/Logd_Disabler_ColorOS16/config.json

# 示例：启用 OTA 阻断（修改后重启生效）
sed -i 's/"block_ota": false/"block_ota": true/' /data/adb/Logd_Disabler_ColorOS16/config.json
```

### 验证状态
```bash
# 执行验证脚本
su
sh /data/adb/modules/Logd_Disabler_ColorOS16/verify_status.sh
```

## 🔧 高级功能

### 实时状态验证
模块内置完整的状态验证脚本，可检查：
- ✅ 每项功能的配置状态
- ✅ 实际系统运行状态（进程、包、属性、内核参数）
- ✅ 设备兼容性检测
- ✅ SELinux状态检查

### 设备适配优化
- **专为一加ACE5优化**：移除了不存在的OPPO专用包
- **智能包检测**：自动识别设备上实际存在的系统包
- **动态配置**：根据设备实际情况调整优化策略

## ⚠️ 注意事项

### 必读警告
- **修改配置后必须重启**才能生效
- **部分功能可能影响系统某些特性**（如健康数据同步、自动备份、语音助手等）
- **禁用系统工具类服务**（如 engineermode、crashbox）可能影响问题诊断

### 故障排除
如果遇到问题：
1. 检查KernelSU模块是否已启用
2. 确认KernelSU版本 >= 0.7.0（WebUI功能需要）
3. 查看模块日志：`cat /data/adb/logd_disabler/service.log` 和 `post-fs-data.log`
4. 查看 SELinux 拒绝：`dmesg | grep avc`
5. 运行验证脚本诊断问题

### 卸载恢复
在KernelSU管理器中**禁用或卸载模块**，mount bind 覆盖会随重启消失，pm disable 的包需手动恢复或重启后重新 enable（建议卸载前先在 WebUI 中关闭所有开关）。

## 🚀 更新日志

### v1.5 (2026-08-09)
- **修复**：彻底解决"包不存在"误判问题——service.sh 不再以 `service check` 判断 PMS 就绪（那只是 binder 服务注册），改为轮询 `pm list packages --user 0` 直到真正能列出包（实测等待约 6 秒），55 个系统包全部 `disable-user 成功`
- **修复**：`pmx()` su 提升机制，统一通过 su 域执行 pm 命令，绕过 ksu 域 SELinux 限制
- **修复**：包存在性检查统一加 `--user 0`，避免多用户环境下输出为空导致误判
- **改进**：新增 `pmx_verbose`（保留 stderr），失败时输出真实错误详情，便于排障
- **改进**：enable 恢复逻辑新增分支——包被卸载时直接走 `install-existing` 恢复
- **安全**：移除 `services.txt` 追踪（涉及设备私有包列表，不再入库）
- **WebUI**：修复 mdui 图标渲染问题（`--outlined` 后缀），全部按钮图标正常显示

### v1.4
- 支持 WebUI 图形化设置界面
- 引入 `persist.sys.coloros16_optimize_gui.*` 属性配置机制

## 📱 兼容性

### 支持设备
- **主要测试设备**: 一加ACE5 (ColorOS 16.0.2)
- **兼容设备**: 所有搭载ColorOS 16的一加/OPPO设备
- **KernelSU版本**: v0.7.0或更高版本（UI功能），v0.5.0+（基础功能）
- **Android版本**: Android 10+

### 已验证功能
✅ 日志系统彻底禁用  
✅ OTA更新完全阻断  
✅ 广告与数据收集屏蔽  
✅ 冗余进程自动查杀  
✅ 内核参数优化生效  
✅ UI控制界面正常工作  

## 📄 许可证

Copyright © 2026 zhangchongjie. All rights reserved.

This module is for personal use only. Redistribution or commercial use without permission is prohibited.

## 💬 反馈与支持

遇到问题或有改进建议？欢迎提交Issue或联系开发者！

---

**💡 提示**: 推荐使用KernelSU UI界面进行配置，简单直观且不易出错。高级用户可通过 `setprop` 命令精细控制每个开关。