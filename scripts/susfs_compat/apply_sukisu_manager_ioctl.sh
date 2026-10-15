#!/bin/bash
# 修复 SukiSU builtin PR #987（动态多管理器签名授权，a2339013/c95d6e2c）
# 引入的内核侧编译错误。全平台构建在 ksu.c 聚合编译阶段命中：
#
#   1) supercall.h 以裸 tag 名声明新 ioctl：
#        DECLARE(__u32, KSU_IOCTL_KPM, _IOWR('K', 106, ksu_manager_cmd));
#      _IOWR 展开为 sizeof(ksu_manager_cmd)，裸 tag 不是类型，clang 报
#      "use of undeclared identifier 'ksu_manager_cmd'"；且复用已存在的
#      KSU_IOCTL_KPM 名字（真正的 KPM ioctl 是 _IOC('K',200)），匿名 enum
#      重复定义报 "redefinition of enumerator 'KSU_IOCTL_KPM'"；同时
#      dispatch.c 处理表引用的 KSU_IOCTL_MANAGER 在头文件里不存在。
#      main 分支同款常量的正确写法是
#      KSU_IOCTL_MANAGER = _IOWR('K', 106, struct ksu_manager_cmd)。
#   2) throne_tracker.c crown_manager() 两形态问题：
#      a2339013：get_pkg_from_apk_path 解析失败分支写裸 return;（非 void
#      函数），clang -Wreturn-type/-Wreturn-mismatch 报错；未定义返回值时
#      调用方按未定值处理，若碰巧 >0 会让扫描提前终止。按文档契约补
#      return 0;（本候选无效、未观察到内置候选、继续扫描；-1 需
#      state->seen 已置位，此处不成立）。c95d6e2c 已自行修复，自动跳过。
#      c95d6e2c：签名改为 (apk, apk_dir, ..., sig_fallback) 后，pkg 数组
#      被移进 if (sig_fallback) 块内声明，而函数尾部的动态管理器扫描循环
#      仍在块外引用——报 "use of undeclared identifier 'pkg'"。把声明上提
#      到函数声明块并初始化为 KSU_PACKAGE_NAME（sig_fallback=false 时跳过
#      内置包名条目，与 fallback 分支"跳过已处理候选"语义一致；fallback
#      路径 get_pkg_* 会覆盖它）。
#
# 全部以内容检测守卫，幂等；上游自行修复后自动跳过。
#
# 用法: apply_sukisu_manager_ioctl.sh <KernelSU_dir>

set -e

KSU_DIR="${1:?usage: apply_sukisu_manager_ioctl.sh <KernelSU_dir>}"
UAPI_FILE="$KSU_DIR/kernel/include/uapi/supercall.h"
THRONE_FILE="$KSU_DIR/kernel/manager/throne_tracker.c"

if [ -f "$UAPI_FILE" ] && grep -q "DECLARE(__u32, KSU_IOCTL_KPM, _IOWR" "$UAPI_FILE" \
  && ! grep -q 'KSU_IOCTL_MANAGER,' "$UAPI_FILE"; then
  echo "🔧 compat: supercall.h manager ioctl fix (PR #987 typo + missing struct keyword)"
  sed -i "s|^DECLARE(__u32, KSU_IOCTL_KPM, _IOWR('K', 106, .*\$|DECLARE(__u32, KSU_IOCTL_MANAGER, _IOWR('K', 106, struct ksu_manager_cmd));|" "$UAPI_FILE"
  grep -q "DECLARE(__u32, KSU_IOCTL_MANAGER, _IOWR('K', 106, struct ksu_manager_cmd));" "$UAPI_FILE" \
    || { echo "::error::supercall.h KSU_IOCTL_MANAGER fix verification failed"; exit 1; }
  [ "$(grep -c 'DECLARE(__u32, KSU_IOCTL_KPM,' "$UAPI_FILE")" -eq 1 ] \
    || { echo "::error::supercall.h KSU_IOCTL_KPM duplicate not resolved"; exit 1; }
  echo "🔧 compat: KSU_IOCTL_MANAGER defined per main branch; KSU_IOCTL_KPM duplicate removed"
fi

if [ -f "$THRONE_FILE" ] && grep -q 'static int crown_manager' "$THRONE_FILE" \
  && grep -A1 'Failed to get package name from apk path' "$THRONE_FILE" | grep -q '^[[:space:]]*return;[[:space:]]*$'; then
  echo "🔧 compat: throne_tracker.c crown_manager bare return fix (a2339013)"
  sed -i '/Failed to get package name from apk path/{n;s/^\([[:space:]]*\)return;[[:space:]]*$/\1return 0;/}' "$THRONE_FILE"
  grep -A1 'Failed to get package name from apk path' "$THRONE_FILE" | grep -q 'return 0;' \
    || { echo "::error::throne_tracker.c crown_manager return fix verification failed"; exit 1; }
  ! grep -A1 'Failed to get package name from apk path' "$THRONE_FILE" | grep -q '^[[:space:]]*return;[[:space:]]*$' \
    || { echo "::error::throne_tracker.c bare return not removed"; exit 1; }
  echo "🔧 compat: crown_manager unparseable-path exit now returns 0"
fi

if [ -f "$THRONE_FILE" ] && grep -q '^        char pkg\[KSU_MAX_PACKAGE_NAME\];$' "$THRONE_FILE" \
  && grep -q 'strncmp(np->package, pkg, KSU_MAX_PACKAGE_NAME)' "$THRONE_FILE" \
  && ! grep -q 'char pkg\[KSU_MAX_PACKAGE_NAME\] = ' "$THRONE_FILE"; then
  echo "🔧 compat: throne_tracker.c crown_manager pkg scope fix (c95d6e2c)"
  sed -i '/^        char pkg\[KSU_MAX_PACKAGE_NAME\];$/d' "$THRONE_FILE"
  sed -i 's/^    bool builtin_crowned_this_call = false;$/    bool builtin_crowned_this_call = false;\n    char pkg[KSU_MAX_PACKAGE_NAME] = KSU_PACKAGE_NAME;/' "$THRONE_FILE"
  grep -q 'char pkg\[KSU_MAX_PACKAGE_NAME\] = KSU_PACKAGE_NAME;' "$THRONE_FILE" \
    || { echo "::error::throne_tracker.c pkg hoist verification failed"; exit 1; }
  ! grep -q '^        char pkg\[KSU_MAX_PACKAGE_NAME\];$' "$THRONE_FILE" \
    || { echo "::error::throne_tracker.c inner pkg declaration not removed"; exit 1; }
  echo "🔧 compat: pkg hoisted to function scope, initialized to KSU_PACKAGE_NAME"
fi

exit 0
