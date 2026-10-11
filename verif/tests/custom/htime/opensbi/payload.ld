/* S-mode payload for the OpenSBI boot test, at FW_PAYLOAD_OFFSET 0x200000. */
OUTPUT_ARCH("riscv")
ENTRY(_start)
SECTIONS
{
  . = 0x80200000;
  .text : { *(.text.init) *(.text*) }
  .rodata : { *(.rodata*) }
  . = ALIGN(0x1000);
  .tohost : { *(.tohost) }
  .data : { *(.data*) *(.bss*) }
}
