# Windows 编译交接文档(由 win 端 agent 执行)

## 背景

FileTransfer 项目基于 LocalSend 改造,新增两个功能:
1. **Android 相机拍摄发送**(仅 Android,win 不涉及)
2. **接收端复制到剪贴板**(三端:mac/win/Android,win 需要本机编译验证)

源码改动已在 Linux 端完成并通过 `flutter analyze`(0 issues)。Flutter 无法从 Linux 交叉编译 Windows 产物,必须在 win 本机编译。本文档指导 win 端从零搭建环境并出 debug app。

## 一、环境准备(首次约 30-60min)

### 1. Visual Studio(含 C++ 桌面工作负载)

Flutter Windows 桌面构建依赖 MSVC 工具链。安装 **Visual Studio 2022 Community**(免费),安装时勾选:
- **「使用 C++ 的桌面开发」(Desktop development with C++)** 工作负载

> 不需要完整的 VS IDE 也行,但必须有 MSVC + Windows 10/11 SDK。验证:`flutter doctor` 应显示 `[✓] Visual Studio - develop Windows apps`。

### 2. Git(拉源码用)

```powershell
winget install Git.Git
```

### 3. Dart(用于装 fvm)

```powershell
winget install Dart.Dart
# 或访问 https://dart.dev/get-dart 下载安装包
```

### 4. fvm(锁定 Flutter 版本)

```powershell
dart pub global activate fvm
```

把 fvm 加入 PATH(fvm 装完会提示路径,通常在 `%LOCALAPPDATA%\Pub\Cache\bin`):

```powershell
# PowerShell 永久加入
[Environment]::SetEnvironmentVariable("Path", $env:Path + ";$env:LOCALAPPDATA\Pub\Cache\bin", "User")
# 重开 PowerShell 后
fvm --version
```

## 二、拉源码 + 对齐 Flutter

### 方式 A:从同一 git 远端拉(推荐)
> 需 Linux 端先 `git push`。若远端未就绪,用方式 B 传整个目录。

```powershell
git clone <远端地址> C:\localsend
cd C:\localsend
git pull
```

### 方式 B:直接拷贝 Linux 端的源码目录到 win

```bash
# Linux 端打包(排除 build/.dart_tool 等大目录)
cd /home/chenxiaobai/Projects/localsend
tar --exclude='build' --exclude='.dart_tool' --exclude='.fvm' \
    -czf /tmp/localsend-src.tar.gz .
# 用 scp / 共享盘传到 win 后解压到 C:\localsend
```

### 对齐 Flutter 版本

项目 `.fvmrc` 锁定 Flutter **3.38.10**,必须用 fvm 对齐,否则 build 失败:

```powershell
cd C:\localsend
fvm install            # 装 3.38.10
fvm use 3.38.10
cd app
fvm flutter pub get
fvm dart run build_runner build --delete-conflicting-outputs   # 生成 slang + mapper(必跑)
```

## 三、编译 debug app

```powershell
cd C:\localsend\app
fvm flutter build windows --debug
```

首次编译约 10-30min。产物:

```
build\windows\x64\runner\Debug\localsend_app.exe
```

> 整个 `Debug` 文件夹是一套(`localsend_app.exe` + `flutter_windows.dll` + `data/` 等),不能只拷 exe,要把整个文件夹一起运行/分发。

双击 `localsend_app.exe` 运行。

## 四、验证(复制到剪贴板功能,win 当接收方)

接收端必须跑**改后 app**,不能是官方版。用上面编译的 debug app 替换官方版测试。

> 用另一台设备(mac/win/Linux-CLI/mate-30-5g 任一)给这台 win 发文件。

1. **图片**:另一端发图给 win → win 进度页完成 → 点该行的「复制」图标(`Icons.content_copy`)→ 在画图/聊天/Word 粘贴,应得到图片 ✅
2. **文本文件**:发 `.txt` → 接收完成 → 点复制 → 粘贴得到文本内容 ✅
3. **普通文件**:发 `.pdf` → 点复制 → 在资源管理器粘贴,应得到文件 ✅
4. **自动复制**:打开改后 app → Settings → Receive → 开「Copy received files to clipboard automatically」→ 再收一张图 → **不点按钮**,直接去其他 app 粘贴,应自动得到图片 ✅

## 五、改动涉及的源码(win 端无需改,仅参考)

| 文件 | 改动 |
|---|---|
| `app/lib/util/clipboard_helper.dart` | 新建,按类型智能复制(文本/图片/文件路径) |
| `app/lib/pages/progress_page.dart` | 接收完成文件行加复制按钮 |
| `app/lib/provider/network/server/controller/receive_controller.dart` | 自动复制:会话完成时写剪贴板 |
| `app/lib/model/state/settings_state.dart` 等 | 加 `autoCopyToClipboard` 设置(默认关) |
| `app/lib/pages/tabs/settings_tab.dart` | 设置开关 UI |

win 上 `pasteboard.writeImage`(GDI+)和 `pasteboard.writeFiles`(`CF_HDROP`)原生实现齐全,无需额外依赖。

## 六、常见问题

- **build_runner 报错**:确保用 `fvm dart`(不是系统 dart)跑,且 `fvm flutter pub get` 已执行。
- **「Visual Studio not installed」**:确认装了「使用 C++ 的桌面开发」工作负载,不只是 .NET。`flutter doctor -v` 看 Windows toolchain 详情。
- **Rust 依赖**:LocalSend 用 flutter_rust_bridge。首次 build 会自动下载/编译 Rust 部分,需联网。若提示缺 Rust target,装 `rustup target add x86_64-pc-windows-msvc`。
- **中文路径**:避免把项目放在含中文/空格的路径,可能引发构建问题,建议放 `C:\localsend`。
- **防火墙**:首次运行会弹 Windows 防火墙授权,勾「专用网络」允许,否则收不到文件。
