#!/usr/bin/env bash
# ============================================================
#  Polaris 一键推送脚本
#  目标仓库: https://github.com/Y4s7cyzyfm-png/Polaris
#  适用平台: macOS / Linux / Windows (Git Bash)
#
#  认证方式（按优先级自动选择，脚本本身不包含任何密码）:
#    1. 环境变量 GITHUB_TOKEN（你的 fine-grained PAT）
#    2. 本机已登录的 gh CLI
#    3. 系统凭据（macOS 钥匙串 / git credential helper）
#
#  用法:
#    cd Polaris
#    GITHUB_TOKEN=你的PAT ./push.sh        # 方式 1
#    ./push.sh                            # 方式 2 / 3
# ============================================================
set -euo pipefail

REPO_SLUG="Y4s7cyzyfm-png/Polaris"
PUBLIC_URL="https://github.com/${REPO_SLUG}"
CLEAN_URL="https://github.com/${REPO_SLUG}.git"

cd "$(dirname "$0")"

# ---------- 0. 基础检查 ----------
command -v git >/dev/null 2>&1 || { echo "[x] 未找到 git，请先安装 Git"; exit 1; }

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "[x] 当前目录不是 git 仓库，请先运行: git init -b main && git add -A && git commit -m 'Initial commit'"
  exit 1
fi

# ---------- 1. 自动提交未保存的变更 ----------
if ! git diff-index --quiet HEAD -- 2>/dev/null || [ -n "$(git ls-files --others --exclude-standard)" ]; then
  echo "[*] 检测到未提交变更，自动提交..."
  git add -A
  git commit -m "Update Polaris" >/dev/null 2>&1 || true
fi

BRANCH=$(git branch --show-current)
[ -n "$BRANCH" ] || BRANCH=main
echo "[*] 本地分支: $BRANCH  最新提交: $(git log --oneline -1 | head -c 60)"

# ---------- 2. 确定认证方式 ----------
TOKEN="${GITHUB_TOKEN:-}"
if [ -z "$TOKEN" ] && command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  TOKEN=$(gh auth token 2>/dev/null || true)
  [ -n "$TOKEN" ] && echo "[*] 使用 gh CLI 已保存的凭据"
fi

if [ -n "$TOKEN" ]; then
  [ -z "${GITHUB_TOKEN:-}" ] && echo "[*] 使用 gh CLI 凭据" || echo "[*] 使用环境变量 GITHUB_TOKEN"
  PUSH_URL="https://oauth2:${TOKEN}@github.com/${REPO_SLUG}.git"
else
  echo "[*] 使用系统凭据（首次推送时 macOS 会弹钥匙串授权）"
  PUSH_URL="$CLEAN_URL"
fi

# 对外输出时隐藏 token 的清洗函数
mask() { sed -e "s|oauth2:[^@]*@|oauth2:****@|g" -e "s|//[A-Za-z0-9_]*@|//****@|g"; }

# ---------- 3. 探测远程仓库状态 ----------
echo "[*] 探测远程仓库状态..."
set +e
LS_OUT=$(git ls-remote "$PUSH_URL" 2>/tmp/polaris_ls_err)
LS_CODE=$?
set -e

if [ "$LS_CODE" -ne 0 ]; then
  echo "[!] 无法读取远程仓库，原因:"
  mask < /tmp/polaris_ls_err | sed 's/^/      /'
  rm -f /tmp/polaris_ls_err
  echo
  echo "    常见原因与解决办法:"
  echo "    a) 仓库不存在 -> 浏览器打开 https://github.com/new 创建 ${REPO_SLUG}（不要勾选初始化 README）"
  echo "       或已安装 gh CLI 时执行: gh repo create ${REPO_SLUG} --public"
  echo "    b) token 权限不足 -> 确认 PAT 已勾选该仓库的 Contents: Read and write"
  echo "    c) 网络问题 -> 检查是否需要代理"
  exit 1
fi
rm -f /tmp/polaris_ls_err

if [ -n "$LS_OUT" ]; then
  echo "[!] 远程仓库已有内容，为安全起见脚本不会覆盖。"
  echo "    如需强制覆盖: git push ${CLEAN_URL} ${BRANCH} --force"
  echo "    如需合并入远程: git pull --rebase ${CLEAN_URL} ${BRANCH} && git push ${CLEAN_URL} ${BRANCH}"
  exit 1
fi
echo "[*] 远程为空仓库，可以直接推送"

# ---------- 4. 推送 ----------
echo "[*] 推送中..."
set +e
git push -u "$PUSH_URL" "$BRANCH" 2>/tmp/polaris_push_err
PUSH_CODE=$?
set -e

if [ "$PUSH_CODE" -ne 0 ]; then
  echo "[x] 推送失败，原因:"
  mask < /tmp/polaris_push_err | sed 's/^/      /'
  rm -f /tmp/polaris_push_err
  exit 1
fi
rm -f /tmp/polaris_push_err

# ---------- 5. 收尾：origin 固定为不带 token 的地址 ----------
git remote remove origin >/dev/null 2>&1 || true
git remote add origin "$CLEAN_URL"
git branch --set-upstream-to="origin/${BRANCH}" "$BRANCH" >/dev/null 2>&1 || true

echo
echo "[OK] 推送完成!"
echo "     仓库地址: ${PUBLIC_URL}"
echo "     后续更新只需: git add -A && git commit -m '...' && git push"
