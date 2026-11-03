#!/bin/bash
# Dawn 一键全验。前提：完整 Xcode 已安装且
#   sudo xcode-select -s /Applications/Xcode.app
# [1/2] 逻辑断言（macOS 本机即可跑的部分）
# [2/2] watchOS 免签名编译（对全部 WatchKit/SwiftKit 代码做真实类型检查；
#       不安装到设备，真机验收仍按 docs/TEST_PLAN.md）
set -uo pipefail
cd "$(dirname "$0")/.."

echo "==== [1/2] 逻辑断言 ===="
if ! ./logic-check/run.sh; then
  echo "✘ 逻辑断言未全部通过，先修复再继续"
  exit 1
fi

echo ""
echo "==== [2/2] watchOS 编译验证（generic / 免签名）===="
LOG=/tmp/dawn-xcodebuild.log
BUILD_FAILED=0
xcodebuild -project DawnWatch.xcodeproj \
  -target DawnWatch \
  -sdk watchos \
  -configuration Debug \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
  COMPILER_INDEX_STORE_ENABLE=NO \
  build > "$LOG" 2>&1 || BUILD_FAILED=1

grep -E "error:|warning:" "$LOG" | sort -u | head -40
grep -E "BUILD (SUCCEEDED|FAILED)" "$LOG"

if [ "$BUILD_FAILED" = "0" ] && grep -q "BUILD SUCCEEDED" "$LOG"; then
  echo ""
  echo "✔ 全部通过：逻辑断言 + watchOS 编译。下一步按 docs/TEST_PLAN.md 真机验收。"
  exit 0
else
  echo ""
  echo "✘ 编译失败，完整日志: $LOG"
  exit 1
fi
