# 发布流程

仓库保持私有；主分支为 `main`。版本采用 `v主版本.次版本.修订版本` 标签。首个 GitHub Release 沿用应用版本 `v1.2.2`。

## 1. 准备版本

1. 更新根目录 `VERSION`，递增 `BUILD_NUMBER`。
2. 更新 `CHANGELOG.md`、README 示例文件名与 `docs/release-notes.md`。
3. 明确最低 macOS、二进制架构、签名和公证状态，以及已知限制。
4. 检查工作目录中的私人文件是否仍被 `.gitignore` 排除。

## 2. 验证

```bash
bash scripts/test.sh
swift build -c release
BIN="$(swift build -c release --show-bin-path)"
"$BIN/GuardBench" --self-test
python3 scripts/regression-polling.py
for script in scripts/*.sh; do bash -n "$script"; done
python3 -m py_compile scripts/*.py
git diff --check
```

完整隔离回归适合在具备有效本地路由和网卡的 macOS 机器上运行。GitHub CI 执行不依赖代理状态的测试、自检、正式构建和隐私扫描。管理员初始化、真实 Claude 故障注入及卸载交互按 [验收清单](acceptance.md) 单独验证，不在构建脚本中自动执行。

## 3. 暂存并扫描

使用明确文件列表或审查过的 `git add`。提交前运行：

```bash
python3 scripts/check-privacy.py
```

再用 Gitleaks 等密钥检测工具扫描暂存源码或其导出副本。内置检查只覆盖常见凭证、绝对用户路径和明确禁止的本地文件，不能识别全部私人内容，因此仍需审查新增文档、图片和配置。

提交使用 GitHub noreply 邮箱，不提交个人真实邮箱。

## 4. 构建发行包

```bash
bash scripts/package-release.sh
```

产物位于 `build/release/`：

- `Claude-Guard-<version>-<arch>.dmg`
- `Claude-Guard-<version>-<arch>.zip`
- `uninstall.sh`
- `SHA256SUMS.txt`

打包会验证代码签名和 DMG、扫描应用中的私人路径和常见凭证，并生成校验清单。使用干净临时目录解压 ZIP、只读挂载 DMG，复查版本、架构、安装资源及内容扫描。只上传预期的四个附件，避免把旧版本产物一起发布。

构建输出默认为当前机器的原生架构。首发仅验证 arm64。Developer ID 签名和公证尚未集成，不得将 ad-hoc 签名标记为已公证。

## 5. 创建标签与 Release

确认本地和 GitHub CI 通过后：

```bash
VERSION="$(cat VERSION)"
git tag -a "v$VERSION" -m "Claude Guard $VERSION"
git push origin main "v$VERSION"
gh release create "v$VERSION" \
  "build/release/Claude-Guard-$VERSION-arm64.dmg" \
  "build/release/Claude-Guard-$VERSION-arm64.zip" \
  build/release/uninstall.sh build/release/SHA256SUMS.txt \
  --verify-tag --title "Claude Guard v$VERSION" \
  --notes-file docs/release-notes.md
```

也可在 Actions 手动运行 **Prepare release**，输入已存在且与 VERSION 一致的版本标签。工作流从标签重新构建并创建草稿 Release；检查附件后再发布。此工作流使用 `contents: write`，普通 CI 只有读权限；第三方 action 固定到具体提交。

## 6. 核对远端

检查仓库可见性为 PRIVATE，标签指向预期提交，Release 不是错误的预发布版本。下载发布后的附件，校验 SHA-256 与本地产物一致，并保留测试记录在本地忽略目录中。
