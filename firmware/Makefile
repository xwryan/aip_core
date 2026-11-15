# AIP CPU firmware build (XuanTie C908, RV64): make poll|msip|plic|all -> build/<wake>[_<boot>].hex.
# BOOT=rom (XIP, default) | ram_copy (ROM→RAM copy) | ram_jump (stub→RAM).
# 默认用 XuanTie 工具链绝对路径（避免 PATH 命中 /usr/bin 通用 gcc），可用 CROSS=... 覆盖。

CROSS   ?= /home/ubuntu/aip_xuantie/Xuantie-900-gcc-elf-newlib-x86_64-V3.4.0/bin/riscv64-unknown-elf-
CC      := $(CROSS)gcc
OBJCOPY := $(CROSS)objcopy
OBJDUMP := $(CROSS)objdump

ARCH ?= rv64gc
ABI  ?= lp64
CFLAGS := -march=$(ARCH) -mabi=$(ABI) -mcmodel=medany -O2 -g \
          -nostdlib -nostartfiles -ffreestanding -fno-builtin \
          -Wall -Wextra -Iapp -Icore

BOOT ?= rom
ifeq ($(BOOT),rom)
LDSCRIPT  := arch/linker.xuantie.ld
BOOT_SFX  :=
BOOT_DEF  :=
BOOT_STUB :=
else ifeq ($(BOOT),ram_copy)
LDSCRIPT  := arch/linker.ram_copy.ld
BOOT_SFX  := _ram_copy
BOOT_DEF  := -DAIP_BOOT_RAM_COPY
BOOT_STUB :=
else ifeq ($(BOOT),ram_jump)
LDSCRIPT  := arch/linker.ram_jump.ld
BOOT_SFX  := _ram_jump
BOOT_DEF  :=
BOOT_STUB := arch/boot_stub.S
else
$(error BOOT=$(BOOT) invalid — use rom|ram_copy|ram_jump)
endif

BUILD      := build
COMMON_SRC := app/main.c app/user_cmds.c core/aip_cmd.c core/handlers.c
ASM_SRC    := arch/startup.S $(BOOT_STUB)

# 顶层 wake 目标递归调用 _img，并传入 WAKE/EXTRA_SRC/EXTRA_DEF。
.PHONY: poll msip plic all clean
poll: ; @$(MAKE) --no-print-directory _img WAKE=poll EXTRA_SRC= EXTRA_DEF=
msip: ; @$(MAKE) --no-print-directory _img WAKE=msip EXTRA_SRC=core/aip_cmd_msip.c EXTRA_DEF=-DAIP_USE_MSIP
plic: ; @$(MAKE) --no-print-directory _img WAKE=plic EXTRA_SRC=core/aip_cmd_c908.c EXTRA_DEF=-DAIP_USE_IRQ
all:  ; @$(MAKE) poll && $(MAKE) msip && $(MAKE) plic
clean: ; rm -rf $(BUILD)

NAME   := $(WAKE)$(BOOT_SFX)
OBJDIR := $(BUILD)/$(NAME)
SRCS   := $(COMMON_SRC) $(EXTRA_SRC)
OBJS   := $(addprefix $(OBJDIR)/,$(notdir $(SRCS:.c=.o))) $(addprefix $(OBJDIR)/,$(notdir $(ASM_SRC:.S=.o)))
ELF    := $(BUILD)/$(NAME).elf
HEX    := $(BUILD)/$(NAME).hex
MAP    := $(BUILD)/$(NAME).map

.PHONY: _img
_img: $(HEX)

$(OBJDIR):
	@mkdir -p $@

# 显式按目录的 pattern 规则 (basename 唯一, 无冲突)
$(OBJDIR)/%.o: app/%.c | $(OBJDIR)
	$(CC) $(CFLAGS) $(EXTRA_DEF) $(BOOT_DEF) -c -o $@ $<
$(OBJDIR)/%.o: core/%.c | $(OBJDIR)
	$(CC) $(CFLAGS) $(EXTRA_DEF) $(BOOT_DEF) -c -o $@ $<
$(OBJDIR)/%.o: arch/%.S | $(OBJDIR)
	$(CC) $(CFLAGS) $(EXTRA_DEF) $(BOOT_DEF) -c -o $@ $<

$(ELF): $(OBJS)
	$(CC) $(CFLAGS) -nostdlib -T $(LDSCRIPT) -Wl,-Map=$(MAP) -o $@ $(OBJS)

$(HEX): $(ELF)
	$(OBJCOPY) -O verilog $< $@
	@echo "built $(HEX)"
