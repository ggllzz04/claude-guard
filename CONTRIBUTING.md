# 开发说明

此私有项目的源码和发行包受 LICENSE 约束。

## 环境

macOS 26+、Swift 6.2+、macOS 26+ SDK 与 Python 3.10+。只编译应用可使用 Command Line Tools；CI 使用 macOS 26 的完整 Xcode 环境。项目没有第三方 Swift Package 依赖。

## 构建与测试

```bash
bash scripts/test.sh
swift build -c release
BIN="$(swift build -c release --show-bin-path)"
"$BIN/GuardBench" --self-test
python3 scripts/regression-polling.py
bash scripts/package-release.sh
```

测试使用 Swift Testing；`scripts/test.sh` 关闭 XCTest，并在需要时显式加载 Command Line Tools 自带的 Testing 宏插件。隔离回归使用临时 Unix socket、合成 API 响应和一次性 GuardMock 进程；不使用真实订阅、节点或设置文件，也不修改 Clash、PF 或真实 Claude。回归仍会只读检查本机路由、网卡和代理状态，完整结果只写入忽略的 `build/` 目录。

守护进程与 IPC、安装器权限、进程识别和关闭策略的改动应补充针对行为的测试。普通界面文案或布局修改可通过构建和界面检查验证。

## 提交前

```bash
for script in scripts/*.sh; do bash -n "$script"; done
python3 -m py_compile scripts/*.py
git diff --check
git add <准备提交的文件>
python3 scripts/check-privacy.py
```

隐私扫描默认检查 Git 暂存区的实际内容，不会将整个工作目录加入版本控制。新增含本机信息的文件，应放入忽略的 `private/` 或 `backup/`。

## 约定

- Swift / shell / Python 使用 4 空格缩进；YAML / JSON 使用 2 空格。
- `GuardKit` 保持检查逻辑与 UI 分离。root 操作只在明确授权的服务路径执行。
- 测试夹具使用虚构名称、保留地址或本地回环；不引用个人配置与截图。
- 用途明确的文件优先放在现有目录；避免提交构建产物和一次性审计材料。
- 发布流程见 [docs/releasing.md](docs/releasing.md)。
