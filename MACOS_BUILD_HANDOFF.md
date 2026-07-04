# macOS 编译交接文档(由 mac 端 agent 执行)

## 背景

FileTransfer 项目基于 LocalSend 改造,新增两个功能:
1. **Android 相机拍摄发送**(仅 Android,mac 不涉及)
2. **接收端复制到剪贴板**(三端:mac/win/Android,mac 需要本机编译验证)

源码改动已在 Linux 端完成并通过 `flutter analyze`(0 issues)。Flutter 无法从 Linux 交叉编译 macOS 产物,必须在 mac 本机编译。本文档指导 mac 端从零搭建环境并出 debug app。

## 一、环境准备(首次约 30-60min)

### 1. Xcode Command Line Tools
```bash
xcode-select --install
# 若已装会提示 already installed,跳过
```

### 2. Dart(用于装 fvm)
mac 自带 ruby/python 但无 dart。用 Homebrew 装:
```bash
brew install dart
```

### 3. fvm(锁定 Flutter 版本)
```bash
dart pub global activate fvm
# 把 fvm 加入 PATH(fvm 装完会提示路径,通常是 ~/.pub-cache/bin)
echo 'export PATH="$HOME/.pub-cache/bin:$PATH"' >> ~/.zshrc
source ~/.zshrc
fvm --version   # 确认可用
```

### 4. CocoaPods(macOS Flutter 插件依赖)
```bash
sudo gem install cocoapods
# 或 brew install cocoapods
```

## 二、拉源码 + 对齐 Flutter

### 方式 A:从同一 git 远端拉(推荐)
> 需 Linux 端先 `git push`。若远端未就绪,用方式 B 传整个目录。

```bash
git clone <远端地址> ~/localsend
cd ~/localsend
git pull   # 确保拿到最新改动
```

### 方式 B:直接拷贝 Linux 端的源码目录到 mac
```bash
# Linux 端打包(排除 build/.dart_tool 等大目录)
cd /home/chenxiaobai/Projects/localsend
tar --exclude='build' --exclude='.dart_tool' --exclude='.fvm' \
    -czf /tmp/localsend-src.tar.gz .
# scp 到 mac 后解压
```

### 对齐 Flutter 版本
项目 `.fvmrc` 锁定 Flutter **3.38.10**,必须用 fvm 对齐,否则 build 失败:
```bash
cd ~/localsend          # 或解压目录
fvm install             # 装 3.38.10
fvm use 3.38.10
cd app
fvm flutter pub get
fvm dart run build_runner build --delete-conflicting-outputs   # 生成 slang + mapper(必跑)
```

## 三、编译 debug app
```bash
cd ~/localsend/app
fvm flutter build macos --debug
```
首次编译约 10-30min。产物:
```
build/macos/Build/Products/Debug/localsend_app.app
```
双击 `.app` 运行(首次可能需在「系统设置 → 隐私与安全性」允许运行)。

## 四、验证(复制到剪贴板功能,mac 当接收方)

接收端必须跑**改后 app**,不能是官方版。用上面编译的 debug app 替换官方版测试。

> 用另一台设备(mac/win/Linux-CLI/mate-30-5g 任一)给这台 mac 发文件。

1. **图片**:另一端发图给 mac → mac 进度页完成 → 点该行的「复制」图标(`Icons.content_copy`)→ 在「预览/备忘录/聊天」粘贴,应得到图片 ✅
2. **文本文件**:发 `.txt` → 接收完成 → 点复制 → 粘贴得到文本内容 ✅
3. **普通文件**:发 `.pdf` → 点复制 → 在 Finder 粘贴,应得到文件 ✅
4. **自动复制**:打开改后 app → Settings → Receive → 开「Copy received files to clipboard automatically」→ 再收一张图 → **不点按钮**,直接去其他 app 粘贴,应自动得到图片 ✅

## 五、改动涉及的源码(mac 端无需改,仅参考)

| 文件 | 改动 |
|---|---|
| `app/lib/util/clipboard_helper.dart` | 新建,按类型智能复制(文本/图片/文件路径) |
| `app/lib/pages/progress_page.dart` | 接收完成文件行加复制按钮 |
| `app/lib/provider/network/server/controller/receive_controller.dart` | 自动复制:会话完成时写剪贴板 |
| `app/lib/model/state/settings_state.dart` 等 | 加 `autoCopyToClipboard` 设置(默认关) |
| `app/lib/pages/tabs/settings_tab.dart` | 设置开关 UI |

mac 上 `pasteboard.writeImage`(NSImage)和 `pasteboard.writeFiles`(NSURL)原生实现齐全,无需额外依赖。

## 六、常见问题

- **build_runner 报错**:确保用 `fvm dart`(不是系统 dart)跑,且 `fvm flutter pub get` 已执行。
- **CocoaPods 报错**:`cd macos && pod install --repo-update`,或删 `macos/Podfile.lock` 重跑。
- **签名错误**:debug 构建用自动签名,确保 Xcode 里登录了 Apple ID 或用默认 development team。
- **运行被拦**:macOS Gatekeeper 拦截未签名 app → 系统设置 → 隐私与安全性 → 仍要打开。
