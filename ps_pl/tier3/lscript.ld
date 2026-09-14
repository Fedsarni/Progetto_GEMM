/*
 * lscript.ld
 * Author: Federica Sarnataro
 *
 * Linker script for the PS+PL bare-metal C application (Cortex-A9,
 * standalone). Written by hand following the standard Xilinx template
 * for this architecture, rather than generated via "lscript generate":
 * that command requires the rdi_vitis backend, which isn't reachable
 * from a pure command-line flow (see xsct timeout when invoked without
 * the Vitis IDE entry point).
 */
_STACK_SIZE = DEFINED(_STACK_SIZE) ? _STACK_SIZE : 0x2000;
_HEAP_SIZE = DEFINED(_HEAP_SIZE) ? _HEAP_SIZE : 0x2000;
_IRQ_STACK_SIZE = DEFINED(_IRQ_STACK_SIZE) ? _IRQ_STACK_SIZE : 0x100;
_SUPERVISOR_STACK_SIZE = DEFINED(_SUPERVISOR_STACK_SIZE) ? _SUPERVISOR_STACK_SIZE : 0x100;
_ABORT_STACK_SIZE = DEFINED(_ABORT_STACK_SIZE) ? _ABORT_STACK_SIZE : 0x100;
_FIQ_STACK_SIZE = DEFINED(_FIQ_STACK_SIZE) ? _FIQ_STACK_SIZE : 0x100;
_UNDEF_STACK_SIZE = DEFINED(_UNDEF_STACK_SIZE) ? _UNDEF_STACK_SIZE : 0x100;

ENTRY(_boot)

MEMORY
{
   ps7_ddr_0_S_AXI_BASEADDR : ORIGIN = 0x100000, LENGTH = 0x1FF00000
   ps7_ram_0_S_AXI_BASEADDR : ORIGIN = 0x0, LENGTH = 0x30000
}

SECTIONS
{
	.text : {
	KEEP (*(.vectors))
	*(.boot)
	*(.text)
	*(.text.*)
	*(.gnu.linkonce.t.*)
	*(.plt)
	*(.gnu_warning)
	*(.gcc_except_table)
	*(.glue_7)
	*(.glue_7t)
	*(.vfp11_veneer)
	*(.ARM.extab)
	*(.gnu.linkonce.armextab.*)
	} > ps7_ddr_0_S_AXI_BASEADDR

	.init : {
	KEEP (*(.init))
	} > ps7_ddr_0_S_AXI_BASEADDR

	.fini : {
	KEEP (*(.fini))
	} > ps7_ddr_0_S_AXI_BASEADDR

	.rodata : {
	__rodata_start = .;
	*(.rodata)
	*(.rodata.*)
	*(.gnu.linkonce.r.*)
	__rodata_end = .;
	} > ps7_ddr_0_S_AXI_BASEADDR

	.rodata1 : {
	__rodata1_start = .;
	*(.rodata1)
	*(.rodata1.*)
	__rodata1_end = .;
	} > ps7_ddr_0_S_AXI_BASEADDR

	.sdata2 : {
	__sdata2_start = .;
	*(.sdata2)
	*(.sdata2.*)
	*(.gnu.linkonce.s2.*)
	__sdata2_end = .;
	} > ps7_ddr_0_S_AXI_BASEADDR

	.sbss2 : {
	__sbss2_start = .;
	*(.sbss2)
	*(.sbss2.*)
	*(.gnu.linkonce.sb2.*)
	__sbss2_end = .;
	} > ps7_ddr_0_S_AXI_BASEADDR

	.data : {
	__data_start = .;
	*(.data)
	*(.data.*)
	*(.gnu.linkonce.d.*)
	__data_end = .;
	} > ps7_ddr_0_S_AXI_BASEADDR

	.data1 : {
	__data1_start = .;
	*(.data1)
	*(.data1.*)
	__data1_end = .;
	} > ps7_ddr_0_S_AXI_BASEADDR

	.got : { *(.got) } > ps7_ddr_0_S_AXI_BASEADDR
	.got1 : { *(.got1) } > ps7_ddr_0_S_AXI_BASEADDR
	.got2 : { *(.got2) } > ps7_ddr_0_S_AXI_BASEADDR

	.ctors : {
	__CTOR_LIST__ = .;
	KEEP (*crtbegin.o(.ctors))
	KEEP (*(EXCLUDE_FILE(*crtend.o) .ctors))
	KEEP (*(SORT(.ctors.*)))
	KEEP (*(.ctors))
	__CTOR_END__ = .;
	} > ps7_ddr_0_S_AXI_BASEADDR

	.dtors : {
	__DTOR_LIST__ = .;
	KEEP (*crtbegin.o(.dtors))
	KEEP (*(EXCLUDE_FILE(*crtend.o) .dtors))
	KEEP (*(SORT(.dtors.*)))
	KEEP (*(.dtors))
	__DTOR_END__ = .;
	} > ps7_ddr_0_S_AXI_BASEADDR

	.fixup : {
	__fixup_start = .;
	*(.fixup)
	__fixup_end = .;
	} > ps7_ddr_0_S_AXI_BASEADDR

	.eh_frame : { *(.eh_frame) } > ps7_ddr_0_S_AXI_BASEADDR

	.eh_framehdr : {
	__eh_framehdr_start = .;
	*(.eh_framehdr)
	__eh_framehdr_end = .;
	} > ps7_ddr_0_S_AXI_BASEADDR

	.gcc_except_table : { *(.gcc_except_table) } > ps7_ddr_0_S_AXI_BASEADDR

	.mmu_tbl (ALIGN(16384)) : {
	__mmu_tbl_start = .;
	*(.mmu_tbl)
	__mmu_tbl_end = .;
	} > ps7_ddr_0_S_AXI_BASEADDR

	.init_array : {
	__init_array_start = .;
	KEEP (*(SORT_BY_INIT_PRIORITY(.init_array.*) SORT_BY_INIT_PRIORITY(.ctors.*)))
	KEEP (*(.init_array EXCLUDE_FILE (*crtbegin.o *crtbegin?.o *crtend.o *crtend?.o) .ctors))
	__init_array_end = .;
	} > ps7_ddr_0_S_AXI_BASEADDR

	.fini_array : {
	__fini_array_start = .;
	KEEP (*(SORT_BY_INIT_PRIORITY(.fini_array.*) SORT_BY_INIT_PRIORITY(.dtors.*)))
	KEEP (*(.fini_array EXCLUDE_FILE (*crtbegin.o *crtbegin?.o *crtend.o *crtend?.o) .dtors))
	__fini_array_end = .;
	} > ps7_ddr_0_S_AXI_BASEADDR

	.ARM.exidx : {
	__exidx_start = .;
	*(.ARM.exidx*)
	*(.gnu.linkonce.armexidx.*)
	__exidx_end = .;
	} > ps7_ddr_0_S_AXI_BASEADDR

	.preinit_array : {
	__preinit_array_start = .;
	KEEP (*(.preinit_array))
	__preinit_array_end = .;
	} > ps7_ddr_0_S_AXI_BASEADDR

	.jcr : { *(.jcr) } > ps7_ddr_0_S_AXI_BASEADDR

	.sdata : {
	__sdata_start = .;
	*(.sdata)
	*(.sdata.*)
	*(.gnu.linkonce.s.*)
	__sdata_end = .;
	} > ps7_ddr_0_S_AXI_BASEADDR

	.sbss (NOLOAD) : {
	__sbss_start = .;
	*(.sbss)
	*(.sbss.*)
	*(.gnu.linkonce.sb.*)
	__sbss_end = .;
	} > ps7_ddr_0_S_AXI_BASEADDR

	.tdata : {
	__tdata_start = .;
	*(.tdata)
	*(.tdata.*)
	*(.gnu.linkonce.td.*)
	__tdata_end = .;
	} > ps7_ddr_0_S_AXI_BASEADDR

	.tbss : {
	__tbss_start = .;
	*(.tbss)
	*(.tbss.*)
	__tbss_end = .;
	} > ps7_ddr_0_S_AXI_BASEADDR

	.bss (NOLOAD) : {
	. = ALIGN(4);
	__bss_start = .;
	*(.bss)
	*(.bss.*)
	*(.gnu.linkonce.b.*)
	*(COMMON)
	. = ALIGN(4);
	__bss_end = .;
	} > ps7_ddr_0_S_AXI_BASEADDR

	_SDA_BASE_  = __sdata_start  + ((__sbss_end  - __sdata_start)  / 2 );
	_SDA2_BASE_ = __sdata2_start + ((__sbss2_end - __sdata2_start) / 2 );

	.heap (NOLOAD) : {
	. = ALIGN(16);
	_heap_start = .;
	. += _HEAP_SIZE;
	_heap_end = .;
	} > ps7_ddr_0_S_AXI_BASEADDR

	.stack (NOLOAD) : {
	. = ALIGN(16);
	_stack_end = .;
	. += _STACK_SIZE;
	. = ALIGN(16);
	_stack = .;
	__stack = _stack;
	__irq_stack = .;
	. += _IRQ_STACK_SIZE;
	. = ALIGN(16);
	__supervisor_stack = .;
	. += _SUPERVISOR_STACK_SIZE;
	. = ALIGN(16);
	__abort_stack = .;
	. += _ABORT_STACK_SIZE;
	. = ALIGN(16);
	__fiq_stack = .;
	. += _FIQ_STACK_SIZE;
	. = ALIGN(16);
	__undef_stack = .;
	. += _UNDEF_STACK_SIZE;
	. = ALIGN(16);
	} > ps7_ddr_0_S_AXI_BASEADDR

	_end = .;
	end = _end;
}
