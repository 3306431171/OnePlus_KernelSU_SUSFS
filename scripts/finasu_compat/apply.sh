#!/usr/bin/env bash
# FinaSU 内核侧 SUSFS 集成补丁应用
#
# susfs4ksu 各 GKI 分支的 kernel_patches/KernelSU/10_enable_susfs_for_ksu.patch
# 针对 FinaSU（新目录布局）的内核源码生成，用于把 FinaSU 从 inline syscall
# hook 模式改写为 SUSFS 手动钩子模式（五个 GKI 分支的该补丁字节级相同）。
#
# FinaSU master 相对补丁基准存在漂移的文件无法直接套用上游补丁 ——
# 步骤 1 排除这些文件，步骤 2 应用本仓库维护的 susfs_drift_fixes.patch
# （基于 susfs4ksu 同步官方 KernelSU 后的 post-patch 形态与 FinaSU master
# 的三方合并重新适配，保留 FinaSU 自有特性：dynamic manager、avc_spoof、
# app_profile init、late-load、module preinit、uts_view、KSU_GET_INFO_FLAG_* 等）。
#
# 当前漂移文件集（10_enable 基准 9a0fd7d3 → master ef67206b 期间上游重构）：
#   kernel/Makefile                  （format 目标重构为 FORMAT_FILES 变量）
#   kernel/Kbuild                    （preinit runner 依赖 ksu_syscall_table 直调，
#                                      SUSFS 手动钩子模式下强制 KSU_NO_PREINIT 禁用）
#   kernel/core/init.c               （late-load 双分支骨架 + preinit + uts_view init）
#   kernel/feature/selinux_hide.c    （保留 10_enable 的 SUSFS 形态：去掉 inline hook
#                                      机器，但 my_write_context/my_write_access/
#                                      my_setprocattr/initialize_fake_status 仍非 static
#                                      —— 内核侧 SUSFS 补丁在 security/selinux 里直接调它们）
#   kernel/feature/sucompat.c        （userspace_stack_buffer 移入 util.h、
#                                      su_compat_handler 注册等）
#   kernel/hook/setuid_hook.c        （master 的 localized UTS view spoofing 在
#                                      ksu_handle_setresuid 里插入了 uts_view 调用，
#                                      10_enable 的整段重写无法定位；重适配到
#                                      SUSFS 手动钩子的 handle_zygote_setresuid 入口）
#   kernel/include/ksu.h             （恢复 10_enable 误删的 ksu_late_loaded 声明，
#                                      master 的 late-load/get_info 代码仍依赖它）
#   kernel/runtime/boot_event.c      （input hook static key 化）
#   kernel/runtime/ksud_integration.c（preinit 集成、userspace_stack_buffer 移除、
#                                      ksu_handle_execveat_ksud 签名维持旧形态适配；
#                                      另补 ksu_setup_preinit_file /
#                                      ksu_preinit_handle_post_execveat 空实现，内核侧
#                                      fs/exec.c 无条件引用这两个符号）
#   kernel/supercall/dispatch.c      （get_info 新增 late-load/preinit/PR 标志）
#
# FinaSU 上游结构变化导致任一步失败时，需要基于新 master 重新生成
# susfs_drift_fixes.patch：检出 10_enable 基准提交（uapi/supercall.h 版本号
# 对应的 FinaSU 提交），应用 10_enable + 旧 drift patch，与 master 三方合并，
# 对漂移文件重新生成 diff。
#
# 用法: apply.sh [KSU_DIR]（默认 KernelSU；依赖环境变量 SUSFS4KSU 指向
#       已按 GKI 分支克隆的 susfs4ksu 仓库）
set -euo pipefail

KSU_DIR="${1:-KernelSU}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRIFT_PATCH="$SCRIPT_DIR/susfs_drift_fixes.patch"
UPSTREAM_PATCH="${SUSFS4KSU:-$PWD/susfs4ksu}/kernel_patches/KernelSU/10_enable_susfs_for_ksu.patch"

# 漂移文件（与 susfs_drift_fixes.patch 的覆盖范围严格一致）
DRIFT_FILES=(
  kernel/Makefile
  kernel/Kbuild
  kernel/core/init.c
  kernel/feature/selinux_hide.c
  kernel/feature/sucompat.c
  kernel/hook/setuid_hook.c
  kernel/include/ksu.h
  kernel/runtime/boot_event.c
  kernel/runtime/ksud_integration.c
  kernel/supercall/dispatch.c
)

[ -f "$UPSTREAM_PATCH" ] || { echo "::error::未找到 susfs4ksu KSU 侧补丁: $UPSTREAM_PATCH"; exit 1; }
[ -f "$DRIFT_PATCH" ] || { echo "::error::未找到 FinaSU drift-fixes 补丁: $DRIFT_PATCH"; exit 1; }
[ -d "$KSU_DIR/.git" ] || { echo "::error::$KSU_DIR 不是 git 仓库检出，无法应用补丁"; exit 1; }

EXCLUDES=()
for f in "${DRIFT_FILES[@]}"; do
  EXCLUDES+=(--exclude="$f")
done

echo "步骤 1/2: 应用 susfs4ksu 10_enable_susfs_for_ksu.patch（排除 ${#DRIFT_FILES[@]} 个漂移文件）..."
git -C "$KSU_DIR" apply "${EXCLUDES[@]}" "$UPSTREAM_PATCH"

echo "步骤 2/2: 应用 FinaSU drift-fixes（${#DRIFT_FILES[@]} 个漂移文件的重适配）..."
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
# 内核侧 SUSFS 补丁在 security/selinux/{hooks,selinuxfs}.c 里直接调用这些 KSU 符号，
# 缺失即 vmlinux 链接失败（undefined symbol）。
grep -q '^ssize_t my_write_context(' "$KSU_DIR/kernel/feature/selinux_hide.c" \
  || fail "selinux_hide.c 未导出 my_write_context（security/selinux 直接引用）"
grep -q '^ssize_t my_write_access(' "$KSU_DIR/kernel/feature/selinux_hide.c" \
  || fail "selinux_hide.c 未导出 my_write_access（security/selinux 直接引用）"
grep -q '^int my_setprocattr(' "$KSU_DIR/kernel/feature/selinux_hide.c" \
  || fail "selinux_hide.c 未导出 my_setprocattr（security/selinux 直接引用）"
grep -q '^void initialize_fake_status(' "$KSU_DIR/kernel/feature/selinux_hide.c" \
  || fail "selinux_hide.c 未导出 initialize_fake_status（selinuxfs 直接引用）"
grep -q '^int ksu_setup_preinit_file(' "$KSU_DIR/kernel/runtime/ksud_integration.c" \
  || fail "ksud_integration.c 缺少 ksu_setup_preinit_file 空实现（fs/exec.c 无条件引用）"
grep -q '^int ksu_preinit_handle_post_execveat(' "$KSU_DIR/kernel/runtime/ksud_integration.c" \
  || fail "ksud_integration.c 缺少 ksu_preinit_handle_post_execveat 空实现（fs/exec.c 无条件引用）"
if grep -qE 'kernelsu-objs \+= hook/(lsm_hook|syscall_event_bridge|syscall_hook_manager|tp_marker)' "$KSU_DIR/kernel/Kbuild"; then
  fail "Kbuild 仍包含 inline syscall hook 对象，10_enable 补丁未正确应用"
fi
grep -q "DEFINE_STATIC_KEY_TRUE(ksu_su_compat_enabled)" "$KSU_DIR/kernel/feature/sucompat.c" \
  || fail "sucompat.c 缺少 su_compat static key 改造，drift-fixes 应用不完整"
grep -q "## For susfs stuff ##" "$KSU_DIR/kernel/Makefile" \
  || fail "Makefile 缺少 SUSFS 版本探测段落，drift-fixes 应用不完整"
grep -q 'ksu_preinit_init();' "$KSU_DIR/kernel/core/init.c" \
  || fail "init.c 缺少 ksu_preinit_init 调用（FinaSU preinit 特性丢失）"
grep -q 'extern bool ksu_late_loaded;' "$KSU_DIR/kernel/include/ksu.h" \
  || fail "ksu.h 缺少 ksu_late_loaded 声明（late-load/get_info 代码将编译失败）"
grep -q 'ccflags-y += -DKSU_NO_PREINIT' "$KSU_DIR/kernel/Kbuild" \
  || fail "Kbuild 缺少 KSU_NO_PREINIT 强制禁用（preinit 依赖 ksu_syscall_table，SUSFS 模式必须禁用）"
if grep -qE 'kernelsu-objs \+= preinit/' "$KSU_DIR/kernel/Kbuild"; then
  fail "Kbuild 仍编译 preinit 对象（其 ksu_syscall_table 引用将导致链接失败）"
fi
grep -q 'kernelsu-objs += feature/uts_view.o' "$KSU_DIR/kernel/Kbuild" \
  || fail "Kbuild 缺少 uts_view 对象（FinaSU localized UTS view spoofing 特性丢失）"
grep -q 'ksu_uts_view_init()' "$KSU_DIR/kernel/core/init.c" \
  || fail "init.c 缺少 ksu_uts_view_init 调用（FinaSU uts_view 特性丢失）"
grep -q 'ksu_uts_view_on_setresuid(' "$KSU_DIR/kernel/hook/setuid_hook.c" \
  || fail "setuid_hook.c 缺少 uts_view 回调（FinaSU uts_view 特性丢失）"
if grep -qE 'ksu_uts_view_on_setresuid\(old_uid' "$KSU_DIR/kernel/hook/setuid_hook.c"; then
  fail "setuid_hook.c 仍使用 ksu_handle_setresuid 的 old_uid/new_uid（SUSFS 模式下未定义，编译必失败）"
fi

REJS=$(find "$KSU_DIR/kernel" -name '*.rej' 2>/dev/null | wc -l)
[ "$REJS" -eq 0 ] || fail "发现 $REJS 个 .rej 冲突文件"
if grep -rq '^<<<<<<< ' "$KSU_DIR/kernel" 2>/dev/null; then
  fail "存在未解决的冲突标记"
fi

echo "FinaSU SUSFS 内核侧集成补丁应用完成"
