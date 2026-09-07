# program_and_test_pynq_pl.tcl
# Author: Federica
#
# [Tier 3] Stimuli generation for the Pynq-Z1 PL-only target (see the
# internal RTL Coding/Design/Verification guide's "Three-tier Verification
# Architecture" / "Synthesis: host-side software script" section).
#
# Automates the whole board bring-up test: open Hardware Manager -> program
# the bitstream -> write A/B via JTAG-AXI -> set base addresses -> start ->
# poll done -> read back C -> compare against a golden model.
#
# On purpose, the test data and golden model below are a direct Tcl port of
# gemm_axi_vip_tb.sv's stimulus (same formula for A/B, same address
# arithmetic), so a hardware run can be compared value-for-value against the
# simulation run -- same DUT, same stimuli, only the driving mechanism
# changes (AXI VIP class code in sim vs. JTAG-to-AXI Master + this script on
# real hardware), exactly as the Tier 1/2/3 split intends.
#
# Usage: from Vivado Tcl Console (project open or not, doesn't matter),
#   source scripts/program_and_test_pynq_pl.tcl
#
# Prerequisite: gemm_top_pynq_pl_wrapper.bit/.ltx already built (see
# build_pynq_pl.tcl) and the Pynq-Z1 connected via USB (JTAG + power).

######################
## Paths / settings  #
######################

# EDIT to your actual build output location.
set bit_file  {./gemm_pynq_pl_prj/gemm_pynq_pl_prj.runs/impl_1/gemm_top_pynq_pl_wrapper.bit}
set ltx_file  {./gemm_pynq_pl_prj/gemm_pynq_pl_prj.runs/impl_1/gemm_top_pynq_pl_wrapper.ltx}

# --------------------------------------------------------------
# Parameters: MUST match gemm_top_pynq_pl_wrapper's generics
# --------------------------------------------------------------
set ELEM_WIDTH 8
set N          8
set M          8
set L          8

# RESULT_WIDTH = 2*ELEM_WIDTH + ceil(log2(N)); C_WORD_WIDTH rounds that up
# to a whole number of bytes. With the defaults above: 2*8+3=19 -> 24 bits.
set RESULT_WIDTH [expr { 2*$ELEM_WIDTH + int(ceil(log($N)/log(2))) }]
set C_WORD_WIDTH [expr { (($RESULT_WIDTH + 7) / 8) * 8 }]

# Signed range for ELEM_WIDTH-bit test values
set MIN_VAL [expr { -(1 << ($ELEM_WIDTH-1)) }]
set MAX_VAL [expr {  (1 << ($ELEM_WIDTH-1)) - 1 }]
set VAL_RANGE [expr { $MAX_VAL - $MIN_VAL + 1 }]

# --------------------------------------------------------------
# Register map (identical to gemm_axi_vip_tb.sv / the Arty PL-only
# program_and_test_hw.tcl -- gemm_top's axi4lite_ctrl_regs offsets are the
# same on every target, only the crossbar's outer base addresses matter,
# and those match too: 0x0000/0x1000/0x2000/0x3000).
# --------------------------------------------------------------
set ADDR_BRAM_A   0x00000000
set ADDR_BRAM_B   0x00001000
set ADDR_BRAM_C   0x00002000
set ADDR_CTRL     0x00003000
set ADDR_STATUS   0x00003004
set ADDR_BASE_A   0x00003008
set ADDR_BASE_B   0x0000300C
set ADDR_BASE_C   0x00003010

# Row of A / column of B: N*ELEM_WIDTH bits packed together -> this many
# bytes per row/column, i.e. the address stride between consecutive
# rows of A (and columns of B).
set ROW_BYTES [expr { ($N * $ELEM_WIDTH) / 8 }]
# Each 32-bit AXI-lite beat carries this many packed elements.
set ELEMS_PER_WORD [expr { 32 / $ELEM_WIDTH }]

# Each C element occupies a full 32-bit word (address stride), even though
# only the low C_WORD_WIDTH bits carry a meaningful, sign-extended value.
set C_BYTES 4

set POLL_MAX_TRIES 200
set POLL_DELAY_MS   50

#####################################
## Helpers: pack/unpack and golden  #
#####################################

# Two's-complement mask of a signed value into ELEM_WIDTH bits.
proc to_uN {val width} {
    set mask [expr { (1 << $width) - 1 }]
    return [expr { $val & $mask }]
}

# Sign-extend the low `width` bits of an unsigned value.
proc sign_extend {val width} {
    set sign_bit [expr { 1 << ($width - 1) }]
    set mask     [expr { (1 << $width) - 1 }]
    set v [expr { $val & $mask }]
    if {($v & $sign_bit) != 0} {
        set v [expr { $v - (1 << $width) }]
    }
    return $v
}

# Pack ELEMS_PER_WORD signed ELEM_WIDTH-bit values (list, low-to-high index)
# into one unsigned 32-bit word, matching row_word[(k*ELEM_WIDTH) +: ELEM_WIDTH]
# in gemm_axi_vip_tb.sv.
proc pack_word {vals elem_width} {
    set word 0
    set k 0
    foreach v $vals {
        set uv [to_uN $v $elem_width]
        set word [expr { $word | ($uv << ($k * $elem_width)) }]
        incr k
    }
    return $word
}

########################
## Generate test data  #
########################

# mat_a[i][k], mat_b[j][k] (B stored "column-wise": row j of mat_b IS
# column j of the logical B matrix) -- same indexing as gemm_axi_vip_tb.sv.
array set mat_a {}
array set mat_b {}
for {set i 0} {$i < $M} {incr i} {
    for {set k 0} {$k < $N} {incr k} {
        set mat_a($i,$k) [expr { $MIN_VAL + (($i*7 + $k*3) % $VAL_RANGE) }]
    }
}
for {set j 0} {$j < $L} {incr j} {
    for {set k 0} {$k < $N} {incr k} {
        set mat_b($j,$k) [expr { $MIN_VAL + (($j*5 + $k*11) % $VAL_RANGE) }]
    }
}

# Golden model: mat_c_expected[i][j] = sum_k mat_a[i][k] * mat_b[j][k]
array set mat_c_expected {}
for {set i 0} {$i < $M} {incr i} {
    for {set j 0} {$j < $L} {incr j} {
        set sum 0
        for {set k 0} {$k < $N} {incr k} {
            set sum [expr { $sum + $mat_a($i,$k) * $mat_b($j,$k) }]
        }
        set mat_c_expected($i,$j) $sum
    }
}

##########################
## Connect and program   #
##########################

open_hw_manager
connect_hw_server -allow_non_jtag

# open_hw_target throws a raw Vivado error ("No hardware target exists" or
# similar) if nothing is connected/powered/enumerated over JTAG. Catch it
# here and stop with a clear message instead of a bare stack trace -- there
# is nothing to poll or retry: if the board isn't there, it isn't there.
if {[catch {open_hw_target} err]} {
    puts "\[TEST\] ERROR: could not open a hardware target."
    puts "\[TEST\] Vivado said: $err"
    puts "\[TEST\] Check: Pynq-Z1 powered on, USB-JTAG cable connected,"
    puts "\[TEST\] correct USB drivers installed, no other Hardware Manager"
    puts "\[TEST\] session (Vivado GUI or another batch run) already holding it."
    return
}

set dev_list [get_hw_devices]
if {[llength $dev_list] == 0} {
    puts "\[TEST\] ERROR: hardware target opened, but no device enumerated on it."
    puts "\[TEST\] (target found, but the JTAG chain reports zero devices --"
    puts "\[TEST\] check board power and the JTAG cable/connector itself)."
    close_hw_target
    return
}

# On Zynq, the JTAG chain has TWO devices: arm_dap_0 (the PS debug access
# port -- present even though we never boot the PS on this PL-only target)
# and the actual programmable FPGA (xc7z020_0 or similar). arm_dap_0 is NOT
# programmable and will error out on program_hw_devices, so filter it out
# explicitly instead of blindly taking index 0 of the raw list.
set dev_list [get_hw_devices -filter {PROGRAM.FILE != ""}]
if {[llength $dev_list] == 0} {
    # Fallback: some tool versions don't expose PROGRAM.FILE as an
    # always-populated property before a bitstream is attached; filter by
    # name pattern instead (xc7z... = the Zynq's PL device).
    set dev_list [get_hw_devices xc7z*]
}
if {[llength $dev_list] == 0} {
    puts "\[TEST\] ERROR: JTAG chain enumerated (found: [get_hw_devices]),"
    puts "\[TEST\] but no programmable xc7z* device among them -- only"
    puts "\[TEST\] arm_dap_0 and/or something unexpected. Check the board"
    puts "\[TEST\] and cable, or inspect [get_hw_devices] manually."
    close_hw_target
    return
}
set dev [lindex $dev_list 0]
puts "\[TEST\] Programmable device: $dev (full chain: [get_hw_devices])"
current_hw_device $dev
refresh_hw_device -update_hw_probes false $dev

set_property PROGRAM.FILE  $bit_file $dev
set_property PROBES.FILE   $ltx_file $dev
program_hw_devices $dev
refresh_hw_device $dev

set axi_list [get_hw_axis]
if {[llength $axi_list] == 0} {
    puts "\[TEST\] ERROR: device programmed, but no AXI (jtag_axi_0) target found."
    puts "\[TEST\] Likely mismatch between .bit and .ltx (stale probes file from"
    puts "\[TEST\] an older build?) or jtag_axi_0 missing/misconfigured in the design."
    return
}
set axi_target [lindex $axi_list 0]
puts "\[TEST\] Using AXI target: $axi_target"

################################
## Load A: one row at a time  #
## (ELEMS_PER_WORD elements per 32-bit AXI-lite beat, ROW_BYTES apart)
################################

for {set i 0} {$i < $M} {incr i} {
    for {set beat 0} {$beat < [expr {$ROW_BYTES / 4}]} {incr beat} {
        set vals {}
        for {set e 0} {$e < $ELEMS_PER_WORD} {incr e} {
            set k [expr { $beat*$ELEMS_PER_WORD + $e }]
            lappend vals $mat_a($i,$k)
        }
        set word [pack_word $vals $ELEM_WIDTH]
        set addr [format 0x%08X [expr { $ADDR_BRAM_A + $i*$ROW_BYTES + $beat*4 }]]
        set data [format %08X $word]
        create_hw_axi_txn wr_a_${i}_${beat} $axi_target -type WRITE -address $addr -data $data -len 1
        run_hw_axi wr_a_${i}_${beat}
    }
}
puts "\[TEST\] Matrix A loaded ($M rows)"

################################
## Load B: one column at a time
################################

for {set j 0} {$j < $L} {incr j} {
    for {set beat 0} {$beat < [expr {$ROW_BYTES / 4}]} {incr beat} {
        set vals {}
        for {set e 0} {$e < $ELEMS_PER_WORD} {incr e} {
            set k [expr { $beat*$ELEMS_PER_WORD + $e }]
            lappend vals $mat_b($j,$k)
        }
        set word [pack_word $vals $ELEM_WIDTH]
        set addr [format 0x%08X [expr { $ADDR_BRAM_B + $j*$ROW_BYTES + $beat*4 }]]
        set data [format %08X $word]
        create_hw_axi_txn wr_b_${j}_${beat} $axi_target -type WRITE -address $addr -data $data -len 1
        run_hw_axi wr_b_${j}_${beat}
    }
}
puts "\[TEST\] Matrix B loaded ($L columns)"

#############################
## Set base addresses       #
#############################

create_hw_axi_txn wr_basea $axi_target -type WRITE -address $ADDR_BASE_A -data [format %08X $ADDR_BRAM_A] -len 1
run_hw_axi wr_basea
create_hw_axi_txn wr_baseb $axi_target -type WRITE -address $ADDR_BASE_B -data [format %08X $ADDR_BRAM_B] -len 1
run_hw_axi wr_baseb
create_hw_axi_txn wr_basec $axi_target -type WRITE -address $ADDR_BASE_C -data [format %08X $ADDR_BRAM_C] -len 1
run_hw_axi wr_basec
puts "\[TEST\] Base addresses set"

#############
## Start    #
#############

create_hw_axi_txn wr_start $axi_target -type WRITE -address $ADDR_CTRL -data 00000001 -len 1
run_hw_axi wr_start
puts "\[TEST\] Start pulse sent"

#####################################
## Poll STATUS until done (bit0=1)  #
#####################################

set done 0
for {set i 0} {$i < $POLL_MAX_TRIES} {incr i} {
    create_hw_axi_txn rd_status $axi_target -type READ -address $ADDR_STATUS -len 1
    run_hw_axi rd_status
    set status_val [get_property DATA [get_hw_axi_txns rd_status]]
    if {[expr {"0x$status_val" & 1}] == 1} {
        set done 1
        puts "\[TEST\] done after [expr {$i+1}] poll(s)"
        break
    }
    after $POLL_DELAY_MS
}

if {!$done} {
    puts "\[TEST\] TIMEOUT: done never went high after $POLL_MAX_TRIES polls."
} else {
    ##########################################
    ## Read back C and compare vs golden model
    ##########################################
    set errors 0
    for {set i 0} {$i < $M} {incr i} {
        for {set j 0} {$j < $L} {incr j} {
            set addr [format 0x%08X [expr { $ADDR_BRAM_C + ($i*$L + $j)*$C_BYTES }]]
            create_hw_axi_txn rd_c_${i}_${j} $axi_target -type READ -address $addr -len 1
            run_hw_axi rd_c_${i}_${j}
            set c_hex [get_property DATA [get_hw_axi_txns rd_c_${i}_${j}]]
            set c_uns [expr { "0x$c_hex" }]
            set c_val [sign_extend $c_uns $C_WORD_WIDTH]
            set expected $mat_c_expected($i,$j)
            if {$c_val != $expected} {
                incr errors
                puts "\[TEST\] Mismatch at C\[$i\]\[$j\]: got $c_val, expected $expected"
            }
        }
    }

    if {$errors == 0} {
        puts "\[TEST\] PASS - all [expr {$M*$L}] elements of C match the golden model."
    } else {
        puts "\[TEST\] FAIL - $errors mismatches out of [expr {$M*$L}] elements."
    }
}
