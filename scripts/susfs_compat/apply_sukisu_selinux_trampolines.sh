#!/bin/bash
# 为 SukiSU builtin 分支 selinux_hide 的 extern 符号补齐 services.c 跳板。
#
# 背景：SukiSU-Ultra builtin 2026-05-29 (5fb0c079) 同步 tiann/KernelSU 的
# SELinux 新检测修复后，kernel/feature/selinux_hide.c 在 >=6.6 分支把
# security_dump_masked_av_fn / context_struct_compute_av_fn 声明为 extern 函数
# ——上游预期由 services.c 补丁提供这两个跳板符号（builtin c32094a4 提交说明），
# 但 SUSFS 内核主补丁（50_add_susfs_in_gki-*）只在 services.c 提供
# my_security_compute_av_user，不含这两个符号，6.6/6.12 的 SukiSU 构建在
# vmlinux 链接阶段报：
#   ld.lld: error: undefined symbol: context_struct_compute_av_fn
#   >>> referenced by selinux_hide.c:780 (security_compute_av_user_with_policy)
# 本仓库 SukiSU 固定检出 builtin 分支（含 susfs=false 的构建），>=6.6 内核树
# 均需该跳板；<6.6 内核 extern 块不参与编译，跳板冗余但无害。
# 处理方式：在 services.c 末尾追加两个跳板（对同名 static 函数的薄封装，
# 与上游预期形态一致）。services.c 缺少被封装的 static 函数时软跳过
# （<6.6 树本就不需要；若 6.6+ 树真缺会以原始链接错误显性暴露）。
# 幂等：services.c 已有跳板或 selinux_hide 非 extern 模型时自动跳过；
# 上游自行提供符号后本脚本自动失效。
#
# 用法: apply_sukisu_selinux_trampolines.sh <KernelSU_dir> <common_kernel_dir>

set -e

KSU_DIR="${1:?usage: apply_sukisu_selinux_trampolines.sh <KernelSU_dir> <common_kernel_dir>}"
COMMON_DIR="${2:?usage: apply_sukisu_selinux_trampolines.sh <KernelSU_dir> <common_kernel_dir>}"

SELINUX_HIDE="$KSU_DIR/kernel/feature/selinux_hide.c"
SERVICES="$COMMON_DIR/security/selinux/ss/services.c"

if [ ! -f "$SELINUX_HIDE" ]; then
  echo "KernelSU 无 kernel/feature/selinux_hide.c，跳过跳板补齐"
  exit 0
fi
if ! grep -q 'extern void context_struct_compute_av_fn' "$SELINUX_HIDE"; then
  echo "selinux_hide 非 builtin extern 模型，无需跳板"
  exit 0
fi
if [ ! -f "$SERVICES" ]; then
  echo "::warning::未找到 $SERVICES，跳过跳板补齐"
  exit 0
fi
if grep -q 'void context_struct_compute_av_fn(' "$SERVICES"; then
  echo "services.c 已有跳板符号，跳过"
  exit 0
fi
if ! grep -q 'context_struct_compute_av(' "$SERVICES"; then
  echo "::warning::services.c 无 context_struct_compute_av，跳过跳板补齐（该内核树形态不同或不需要）"
  exit 0
fi

echo "补齐 SukiSU builtin selinux_hide 所需的 services.c 跳板符号..."
cat >> "$SERVICES" <<'TRAMPEOF'

/* Trampolines for SukiSU-Ultra builtin selinux_hide (>=6.6 model):
 * kernel/feature/selinux_hide.c declares *_fn as extern; provide thin
 * wrappers around the static implementations here. */
void context_struct_compute_av_fn(struct policydb *policydb,
				  struct context *scontext,
				  struct context *tcontext,
				  u16 tclass,
				  struct av_decision *avd,
				  struct extended_perms *xperms);
void context_struct_compute_av_fn(struct policydb *policydb,
				  struct context *scontext,
				  struct context *tcontext,
				  u16 tclass,
				  struct av_decision *avd,
				  struct extended_perms *xperms)
{
	context_struct_compute_av(policydb, scontext, tcontext, tclass, avd, xperms);
}
TRAMPEOF

if grep -q 'security_dump_masked_av(' "$SERVICES"; then
  cat >> "$SERVICES" <<'TRAMP2EOF'

void security_dump_masked_av_fn(struct policydb *policydb,
				struct context *scontext,
				struct context *tcontext,
				u16 tclass,
				u32 permissions,
				const char *reason);
void security_dump_masked_av_fn(struct policydb *policydb,
				struct context *scontext,
				struct context *tcontext,
				u16 tclass,
				u32 permissions,
				const char *reason)
{
	security_dump_masked_av(policydb, scontext, tcontext, tclass, permissions, reason);
}
TRAMP2EOF
else
  echo "::warning::services.c 无 security_dump_masked_av，跳过对应跳板（其 extern 引用已被编译器消除，不影响链接）"
fi

grep -q 'void context_struct_compute_av_fn(' "$SERVICES" \
  || { echo "::error::services.c 跳板符号追加后校验失败"; exit 1; }
echo "services.c: 已提供 context_struct_compute_av_fn / security_dump_masked_av_fn 跳板"
