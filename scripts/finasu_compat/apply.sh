#!/usr/bin/env bash
# FinaSU 内核侧 SUSFS 集成补丁应用
#
# susfs4ksu 各 GKI 分支的 kernel_patches/KernelSU/10_enable_susfs_for_ksu.patch
# 针对 FinaSU（新目录布局）的内核源码生成，用于把 FinaSU 从 inline syscall
# hook 模式改写为 SUSFS 手动钩子模式（五个 GKI 分支的该补丁字节级相同）。
#
# FinaSU master 相对补丁基准存在两类漂移：
#   1) kernel/runtime/ksud_integration.c 缺少上游后续合入的一行注释
#      （"after apply_kernelsu_rules..."，位于 second_stage 分支内），
#      导致 10_enable 补丁的 @@ -147 hunk 上下文无法命中 —— 步骤 0 先对齐。
#   2) kernel/core/init.c、kernel/feature/selinux_hide.c、
#      kernel/runtime/boot_event.c、kernel/supercall/dispatch.c 四个文件
#      在 FinaSU 内有自有特性（dynamic manager、avc_spoof、app_profile
#      init 等），无法直接套用上游补丁 —— 步骤 1 排除这四个文件，
#      步骤 2 应用本仓库维护的 susfs_drift_fixes.patch（基于
#      susfs4ksu 同步官方 KernelSU 后的 post-patch 形态与 FinaSU master
#      的三方合并重新适配，保留 FinaSU 自有特性）。
#
# FinaSU 上游结构变化导致任一步失败时，需要基于新 master 重新生成
# susfs_drift_fixes.patch（重新执行三方合并并解决冲突）。
#
# 用法: apply.sh [KSU_DIR]（默认 KernelSU；依赖环境变量 SUSFS4KSU 指向
#       已按 GKI 分支克隆的 susfs4ksu 仓库）
set -euo pipefail

KSU_DIR="${1:-KernelSU}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRIFT_PATCH="$SCRIPT_DIR/susfs_drift_fixes.patch"
UPSTREAM_PATCH="${SUSFS4KSU:-$PWD/susfs4ksu}/kernel_patches/KernelSU/10_enable_susfs_for_ksu.patch"

# 4 个漂移文件（与 susfs_drift_fixes.patch 的覆盖范围严格一致）
DRIFT_FILES=(
  kernel/core/init.c
  kernel/feature/selinux_hide.c
  kernel/runtime/boot_event.c
  kernel/supercall/dispatch.c
)

[ -f "$UPSTREAM_PATCH" ] || { echo "::error::未找到 susfs4ksu KSU 侧补丁: $UPSTREAM_PATCH"; exit 1; }
[ -f "$DRIFT_PATCH" ] || { echo "::error::未找到 FinaSU drift-fixes 补丁: $DRIFT_PATCH"; exit 1; }
[ -d "$KSU_DIR/.git" ] || { echo "::error::$KSU_DIR 不是 git 仓库检出，无法应用补丁"; exit 1; }

# ---- 步骤 0: 对齐 ksud_integration.c 的上游注释漂移 ----
# susfs4ksu 同步官方 KernelSU 后，10_enable 补丁的 second_stage hunk
# 期望 ksud_integration.c 在 ksu_feature_apply_forced() 之上有该注释行；
# FinaSU master 尚未合入对应上游提交时由此补齐（幂等）。
KSUD_INTEG="$KSU_DIR/kernel/runtime/ksud_integration.c"
if [ -f "$KSUD_INTEG" ] \
  && ! grep -q "after apply_kernelsu_rules, so that selinux_hide has its sepolicy backup" "$KSUD_INTEG"; then
  echo "步骤 0/2: 对齐 ksud_integration.c 的 second_stage 注释（上游漂移）..."
  sed -i 's/^            ksu_feature_apply_forced();$/            \/\/ after apply_kernelsu_rules, so that selinux_hide has its sepolicy backup\n            ksu_feature_apply_forced();/' "$KSUD_INTEG"
  grep -q "after apply_kernelsu_rules, so that selinux_hide has its sepolicy backup" "$KSUD_INTEG" \
    || { echo "::error::ksud_integration.c 注释对齐失败（ksu_feature_apply_forced 行不存在或缩进变化）"; exit 1; }
fi

EXCLUDES=()
for f in "${DRIFT_FILES[@]}"; do
  EXCLUDES+=(--exclude="$f")
done

echo "步骤 1/2: 应用 susfs4ksu 10_enable_susfs_for_ksu.patch（排除 ${#DRIFT_FILES[@]} 个漂移文件）..."
git -C "$KSU_DIR" apply "${EXCLUDES[@]}" "$UPSTREAM_PATCH"

echo "步骤 2/2: 应用 FinaSU drift-fixes（4 个漂移文件的重适配）..."
git -C "$KSU_DIR" apply "$DRIFT_PATCH"

# ---- 应用结果校验 ----
fail() { echo "::error::$1"; exit 1; }

grep -q "config KSU_SUSFS" "$KSU_DIR/kernel/Kconfig" \
  || fail "Kconfig 缺少 KSU_SUSFS 配置声明，10_enable 补丁未正确应用"
grep -q "susfs_init" "$KSU_DIR/kernel/core/init.c" \
  || fail "init.c 缺少 susfs_init 调用，drift-fixes 应用不完整"
grep -q "ksu_handle_sys_reboot" "$KSU_DIR/kernel/supercall/dispatch.c" \
  || fail "dispatch.c 缺少 ksu_handle_sys_reboot（SUSFS 手动钩子入口），drift-fixes 应用不完整"
grep -q "ksu_selinux_hide_drop_backup_if_unused" "$KSU_DIR/kernel/feature/selinux_hide.c" \
  || fail "selinux_hide.c 缺少 backup 释放接口，drift-fixes 应用不完整"
if grep -qE 'find_kernel_symbol_exact|patch_text' "$KSU_DIR/kernel/feature/selinux_hide.c"; then
  fail "selinux_hide.c 仍包含 inline hook 机器（resolver/patch_text），drift-fixes 应用不完整"
fi
if grep -qE 'kernelsu-objs \+= hook/(lsm_hook|syscall_event_bridge|syscall_hook_manager|tp_marker)' "$KSU_DIR/kernel/Kbuild"; then
  fail "Kbuild 仍包含 inline syscall hook 对象，10_enable 补丁未正确应用"
fi

REJS=$(find "$KSU_DIR/kernel" -name '*.rej' 2>/dev/null | wc -l)
[ "$REJS" -eq 0 ] || fail "发现 $REJS 个 .rej 冲突文件"
if grep -rq '^<<<<<<< ' "$KSU_DIR/kernel" 2>/dev/null; then
  fail "存在未解决的冲突标记"
fi

echo "FinaSU SUSFS 内核侧集成补丁应用完成"
