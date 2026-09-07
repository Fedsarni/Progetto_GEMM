# program_and_test_pynq_pl.tcl
# Author: Federica
#
# [Tier 3] Stimuli generation for the Pynq-Z1 PL-only target (see the
# internal RTL Coding/Design/Verification guide's "Three-tier Verification
# Architecture" / "Synthesis: host-side software script" section).
#
# Automates the whole board bring-up test: open Hardware Manager -> program
# the bitstream -> for each test case (a handful of fixed corner cases +
# a couple of randomized cases -- see gemm_axi_vip_tb.sv for the rationale
# on why exhaustive coverage isn't attempted): write A/B via JTAG-AXI ->
# set base addresses -> start -> poll done -> read back C -> compare
# against a golden model computed in this script.
#
# IMPORTANT: every error path below calls `exit 1` (not `return`). A bare
# `return` only exits this Tcl proc/script but lets the Vivado batch
# process finish with exit code 0 -- which GitHub Actions (and any CI)
# reads as SUCCESS regardless of what actually happened. `exit 1` makes
# the Vivado process itself fail, which is what CI needs to see a red X
# instead of a false-green checkmark. (This bug was caught the first time
# the CI ran with the board disconnected: the job showed green even though
# the test never actually ran.)
#
# Usage: from Vivado Tcl Console (project open or not, doesn't matter),
#   source scripts/program_and_test_pynq_pl.tcl
#
# Prerequisite: gemm_top_pynq_pl_wrapper.bit/.ltx already built (see
# build_pynq_pl.tcl) and the Pynq-Z1 connected via USB (JTAG + power).

######################
## Paths / settings  #
######################

set bit_file  {./gemm_pynq_pl_prj/gemm_pynq_pl_prj.runs/impl_1/gemm_top_pynq_pl_wrapper.bit}
set ltx_file  {./gemm_pynq_pl_prj/gemm_pynq_pl_prj.runs/impl_1/gemm_top_pynq_pl_wrapper.ltx}

set ELEM_WIDTH 8
set N          8
set M          8
set L          8

set RESULT_WIDTH [expr { 2*$ELEM_WIDTH + int(ceil(log($N)/log(2))) }]
set C_WORD_WIDTH [expr { (($RESULT_WIDTH + 7) / 8) * 8 }]

set MIN_VAL [expr { -(1 << ($ELEM_WIDTH-1)) }]
set MAX_VAL [expr {  (1 << ($ELEM_WIDTH-1)) - 1 }]
set VAL_RANGE [expr { $MAX_VAL - $MIN_VAL + 1 }]

set ADDR_BRAM_A   0x00000000
set ADDR_BRAM_B   0x00001000
set ADDR_BRAM_C   0x00002000
set ADDR_CTRL     0x00003000
set ADDR_STATUS   0x00003004
set ADDR_BASE_A   0x00003008
set ADDR_BASE_B   0x0000300C
set ADDR_BASE_C   0x00003010

set ROW_BYTES [expr { ($N * $ELEM_WIDTH) / 8 }]
set ELEMS_PER_WORD [expr { 32 / $ELEM_WIDTH }]
set C_BYTES 4

set POLL_MAX_TRIES 200
set POLL_DELAY_MS   50

# Number of randomized cases run in addition to the fixed corner cases.
# Kept low relative to simulation's NUM_RANDOM_CASES=5: every HIL
# transaction costs real USB/JTAG round-trip time, unlike simulation.
set NUM_RANDOM_CASES 2

#####################################
## Helpers: pack/unpack and golden  #
#####################################

proc to_uN {val width} {
    set mask [expr { (1 << $width) - 1 }]
    return [expr { $val & $mask }]
}

proc sign_extend {val width} {
    set sign_bit [expr { 1 << ($width - 1) }]
    set mask     [expr { (1 << $width) - 1 }]
    set v [expr { $val & $mask }]
    if {($v & $sign_bit) != 0} {
        set v [expr { $v - (1 << $width) }]
    }
    return $v
}

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

##################################################
## Test case generators -- each fills mat_a/mat_b
## (global arrays, same convention as the SV TB)
##################################################

proc gen_case_baseline {} {
    global M N L MIN_VAL MAX_VAL VAL_RANGE
    upvar #0 mat_a mat_a
    upvar #0 mat_b mat_b
    array unset mat_a
    array unset mat_b
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
}

# Both operands at max positive everywhere -- stresses the top of the
# accumulator's dynamic range.
proc gen_case_max_pos {} {
    global M N L MAX_VAL
    upvar #0 mat_a mat_a
    upvar #0 mat_b mat_b
    array unset mat_a
    array unset mat_b
    for {set i 0} {$i < $M} {incr i} { for {set k 0} {$k < $N} {incr k} { set mat_a($i,$k) $MAX_VAL } }
    for {set j 0} {$j < $L} {incr j} { for {set k 0} {$k < $N} {incr k} { set mat_b($j,$k) $MAX_VAL } }
}

# A at max positive, B at max negative -- asymmetric two's-complement
# extreme (|MIN_VAL| > MAX_VAL), classic overflow corner case.
proc gen_case_max_neg {} {
    global M N L MIN_VAL MAX_VAL
    upvar #0 mat_a mat_a
    upvar #0 mat_b mat_b
    array unset mat_a
    array unset mat_b
    for {set i 0} {$i < $M} {incr i} { for {set k 0} {$k < $N} {incr k} { set mat_a($i,$k) $MAX_VAL } }
    for {set j 0} {$j < $L} {incr j} { for {set k 0} {$k < $N} {incr k} { set mat_b($j,$k) $MIN_VAL } }
}

# Alternating-sign checkerboard -- stresses sign-extension and sums with
# heavy positive/negative cancellation.
proc gen_case_checkerboard {} {
    global M N L MIN_VAL MAX_VAL
    upvar #0 mat_a mat_a
    upvar #0 mat_b mat_b
    array unset mat_a
    array unset mat_b
    for {set i 0} {$i < $M} {incr i} {
        for {set k 0} {$k < $N} {incr k} {
            set mat_a($i,$k) [expr { (($i+$k) % 2 == 0) ? $MAX_VAL : $MIN_VAL }]
        }
    }
    for {set j 0} {$j < $L} {incr j} {
        for {set k 0} {$k < $N} {incr k} {
            set mat_b($j,$k) [expr { (($j+$k) % 2 == 0) ? $MIN_VAL : $MAX_VAL }]
        }
    }
}

# Sparse: everything zero except one A element and one B element sharing
# the same k, so exactly one C element is nonzero -- isolates addressing
# bugs from any cancellation that could mask them.
proc gen_case_sparse {} {
    global M N L
    upvar #0 mat_a mat_a
    upvar #0 mat_b mat_b
    array unset mat_a
    array unset mat_b
    for {set i 0} {$i < $M} {incr i} { for {set k 0} {$k < $N} {incr k} { set mat_a($i,$k) 0 } }
    for {set j 0} {$j < $L} {incr j} { for {set k 0} {$k < $N} {incr k} { set mat_b($j,$k) 0 } }
    set sparse_i [expr { 2 % $M }]
    set sparse_k [expr { 3 % $N }]
    set sparse_j [expr { 5 % $L }]
    set mat_a($sparse_i,$sparse_k) 50
    set mat_b($sparse_j,$sparse_k) -30
    ;# Expected: only C[$sparse_i][$sparse_j] = 50*-30 = -1500 is nonzero.
}

proc gen_case_random {} {
    global M N L MIN_VAL MAX_VAL
    upvar #0 mat_a mat_a
    upvar #0 mat_b mat_b
    array unset mat_a
    array unset mat_b
    for {set i 0} {$i < $M} {incr i} {
        for {set k 0} {$k < $N} {incr k} {
            set mat_a($i,$k) [expr { $MIN_VAL + int(rand()*($MAX_VAL-$MIN_VAL+1)) }]
        }
    }
    for {set j 0} {$j < $L} {incr j} {
        for {set k 0} {$k < $N} {incr k} {
            set mat_b($j,$k) [expr { $MIN_VAL + int(rand()*($MAX_VAL-$MIN_VAL+1)) }]
        }
    }
}

proc compute_golden_model {} {
    global M N L
    upvar #0 mat_a mat_a
    upvar #0 mat_b mat_b
    upvar #0 mat_c_expected mat_c_expected
    array unset mat_c_expected
    for {set i 0} {$i < $M} {incr i} {
        for {set j 0} {$j < $L} {incr j} {
            set sum 0
            for {set k 0} {$k < $N} {incr k} {
                set sum [expr { $sum + $mat_a($i,$k) * $mat_b($j,$k) }]
            }
            set mat_c_expected($i,$j) $sum
        }
    }
}

##########################
## Connect and program   #
##########################

open_hw_manager
connect_hw_server -allow_non_jtag

if {[catch {open_hw_target} err]} {
    puts "\[TEST\] ERROR: could not open a hardware target."
    puts "\[TEST\] Vivado said: $err"
    puts "\[TEST\] Check: Pynq-Z1 powered on, USB-JTAG cable connected,"
    puts "\[TEST\] correct USB drivers installed, no other Hardware Manager"
    puts "\[TEST\] session (Vivado GUI or another batch run) already holding it."
    exit 1
}

set dev_list [get_hw_devices]
if {[llength $dev_list] == 0} {
    puts "\[TEST\] ERROR: hardware target opened, but no device enumerated on it."
    puts "\[TEST\] (target found, but the JTAG chain reports zero devices --"
    puts "\[TEST\] check board power and the JTAG cable/connector itself)."
    close_hw_target
    exit 1
}

set dev_list [get_hw_devices -filter {PROGRAM.FILE != ""}]
if {[llength $dev_list] == 0} {
    set dev_list [get_hw_devices xc7z*]
}
if {[llength $dev_list] == 0} {
    puts "\[TEST\] ERROR: JTAG chain enumerated (found: [get_hw_devices]),"
    puts "\[TEST\] but no programmable xc7z* device among them -- only"
    puts "\[TEST\] arm_dap_0 and/or something unexpected. Check the board"
    puts "\[TEST\] and cable, or inspect [get_hw_devices] manually."
    close_hw_target
    exit 1
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
    exit 1
}
set axi_target [lindex $axi_list 0]
puts "\[TEST\] Using AXI target: $axi_target"

################################################
## Common per-case flow (called once per case) #
################################################

proc run_current_case {case_name} {
    global axi_target M N L ROW_BYTES ELEMS_PER_WORD ELEM_WIDTH C_BYTES
    global ADDR_BRAM_A ADDR_BRAM_B ADDR_BRAM_C ADDR_CTRL ADDR_STATUS
    global ADDR_BASE_A ADDR_BASE_B ADDR_BASE_C
    global POLL_MAX_TRIES POLL_DELAY_MS C_WORD_WIDTH
    upvar #0 mat_a mat_a
    upvar #0 mat_b mat_b
    upvar #0 mat_c_expected mat_c_expected

    compute_golden_model

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
            create_hw_axi_txn wr_a_${i}_${beat} $axi_target -type WRITE -address $addr -data $data -len 1 -force
            run_hw_axi wr_a_${i}_${beat}
        }
    }

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
            create_hw_axi_txn wr_b_${j}_${beat} $axi_target -type WRITE -address $addr -data $data -len 1 -force
            run_hw_axi wr_b_${j}_${beat}
        }
    }

    create_hw_axi_txn wr_basea $axi_target -type WRITE -address $ADDR_BASE_A -data [format %08X $ADDR_BRAM_A] -len 1 -force
    run_hw_axi wr_basea
    create_hw_axi_txn wr_baseb $axi_target -type WRITE -address $ADDR_BASE_B -data [format %08X $ADDR_BRAM_B] -len 1 -force
    run_hw_axi wr_baseb
    create_hw_axi_txn wr_basec $axi_target -type WRITE -address $ADDR_BASE_C -data [format %08X $ADDR_BRAM_C] -len 1 -force
    run_hw_axi wr_basec

    create_hw_axi_txn wr_start $axi_target -type WRITE -address $ADDR_CTRL -data 00000001 -len 1 -force
    run_hw_axi wr_start

    set done 0
    for {set i 0} {$i < $POLL_MAX_TRIES} {incr i} {
        create_hw_axi_txn rd_status $axi_target -type READ -address $ADDR_STATUS -len 1 -force
        run_hw_axi rd_status
        set status_val [get_property DATA [get_hw_axi_txns rd_status]]
        if {[expr {"0x$status_val" & 1}] == 1} {
            set done 1
            break
        }
        after $POLL_DELAY_MS
    }

    if {!$done} {
        puts "\[TEST\]\[$case_name\] TIMEOUT: done never went high after $POLL_MAX_TRIES polls."
        return 0
    }

    set errors 0
    for {set i 0} {$i < $M} {incr i} {
        for {set j 0} {$j < $L} {incr j} {
            set addr [format 0x%08X [expr { $ADDR_BRAM_C + ($i*$L + $j)*$C_BYTES }]]
            create_hw_axi_txn rd_c_${i}_${j} $axi_target -type READ -address $addr -len 1 -force
            run_hw_axi rd_c_${i}_${j}
            set c_hex [get_property DATA [get_hw_axi_txns rd_c_${i}_${j}]]
            set c_uns [expr { "0x$c_hex" }]
            set c_val [sign_extend $c_uns $C_WORD_WIDTH]
            set expected $mat_c_expected($i,$j)
            if {$c_val != $expected} {
                incr errors
                puts "\[TEST\]\[$case_name\] Mismatch at C\[$i\]\[$j\]: got $c_val, expected $expected"
            }
        }
    }

    if {$errors == 0} {
        puts "\[TEST\]\[$case_name\] PASS - all [expr {$M*$L}] elements of C match."
    } else {
        puts "\[TEST\]\[$case_name\] FAIL - $errors mismatches out of [expr {$M*$L}] elements."
    }
    return $errors
}

##############################
## Run the full case suite   #
##############################

set total_cases 0
set failed_cases 0
set total_errors 0

puts "\[TEST\] ==== Starting coverage suite: 5 fixed corner cases + $NUM_RANDOM_CASES random cases ===="

foreach {gen_proc case_name} {
    gen_case_baseline     baseline
    gen_case_max_pos      max_positive_saturation
    gen_case_max_neg      max_negative_saturation
    gen_case_checkerboard sign_checkerboard
    gen_case_sparse       sparse_single_element
} {
    $gen_proc
    set errs [run_current_case $case_name]
    incr total_cases
    incr total_errors $errs
    if {$errs != 0} { incr failed_cases }
}

for {set r 0} {$r < $NUM_RANDOM_CASES} {incr r} {
    gen_case_random
    set errs [run_current_case "random_$r"]
    incr total_cases
    incr total_errors $errs
    if {$errs != 0} { incr failed_cases }
}

puts "\[TEST\] ==== Coverage suite summary ===="
puts "\[TEST\] Cases run: $total_cases, cases failed: $failed_cases, total element mismatches: $total_errors"

if {$failed_cases == 0} {
    puts "\[TEST\] OVERALL PASS - all $total_cases test cases passed."
} else {
    puts "\[TEST\] OVERALL FAIL - $failed_cases of $total_cases test cases failed."
    exit 1
}

 
