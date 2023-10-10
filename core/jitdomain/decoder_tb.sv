// Author: Quentin Ducasse, ENSTA Bretagne
// Date: 10.10.2023
// Description: Self-contained testbench for the decoder, modeled after the pmp one

import ariane_pkg::*;

module decoder_tb;
    timeunit 1ns;
    timeprecision 1ps;

    // Inputs - Testing
    logic [64:0]            pc;
    logic [31:0]            instruction;
    riscv::dmp_domain_t     curdom;
    // Outputs - Asserting
    scoreboard_entry_t      decoded_instruction;
    logic                   is_control_flow_instr;

    decoder #(   
    ) i_decoder(
        // Debug
        .debug_req_i             ( '0                     ),
        // Compressed instructions
        .is_compressed_i         ( '0                     ),
        .compressed_instr_i      ( '0                     ),
        .is_illegal_i            ( '0                     ),
        // Branch predict
        .branch_predict_i        ( '0                     ),
        // Exception during fetch
        .ex_i                    ( '0                     ),
        .irq_i                   ( '0                     ),
        .irq_ctrl_i              ( '0                     ),
        .priv_lvl_i              ( riscv::PRIV_LVL_U      ),
        .debug_mode_i            ( '0                     ),
        .fs_i                    ( riscv::Off             ),
        .frm_i                   ( '0                     ),
        .vs_i                    ( riscv::Off             ),
        .tvm_i                   ( '0                     ),
        .tw_i                    ( '0                     ),
        .tsr_i                   ( '0                     ),
        // Testing signal
        .pc_i                    ( pc                     ),
        .instruction_i           ( instruction            ),
        .curdom_i                ( curdom                 ),
        .instruction_o           ( decoded_instruction    ),
        .is_control_flow_instr_o ( is_control_flow_instr  )
    );

    initial begin
        pc = 32'h80000000;

        // -------------------------------
        // 1st test batch: lb decoding
        instruction = 32'h02830383; // lb t2,40(t1)

        // 1.1 curdom = DOMI
        curdom = riscv::DOMI;
        #5ns;
        assert(decoded_instruction.op == LB);                // Correct opcode
        assert(decoded_instruction.ex.valid == 0);           // No exception
        assert(decoded_instruction.code_dom == riscv::DOMI); // Executed from domain 0/1
        assert(decoded_instruction.data_dom == riscv::DOM0); // Accesses domain 0
        assert(decoded_instruction.chg_dom  == 0);           // Should not change dom

        // 1.2 curdom = DOM0
        curdom = riscv::DOM0;
        #5ns; // No exception
        assert(decoded_instruction.ex.valid == 0);

        // 1.3 curdom = DOM1
        curdom = riscv::DOM1;
        #5ns; // No exception
        assert(decoded_instruction.ex.valid == 0);

        // 1.4 curdom = DOM2
        curdom = riscv::DOM2;
        #5ns; // Exception raised!
        assert(decoded_instruction.ex.valid == 1);
        assert(decoded_instruction.ex.cause == riscv::ILLEGAL_INSTR);

        // -------------------------------
        // 2nd test batch: sb decoding
        instruction = 32'h02730423; // sb t2,40(t1)

        // 2.1 curdom = DOMI
        curdom = riscv::DOMI;
        #5ns;
        assert(decoded_instruction.op == SB);                // Correct opcode
        assert(decoded_instruction.ex.valid == 0);           // No exception
        assert(decoded_instruction.code_dom == riscv::DOMI); // Executed from domain 0/1
        assert(decoded_instruction.data_dom == riscv::DOM0); // Accesses domain 0
        assert(decoded_instruction.chg_dom  == 0);           // Should not change dom

        // 2.2 curdom = DOM0
        curdom = riscv::DOM0;
        #5ns; // No exception
        assert(decoded_instruction.ex.valid == 0);

        // 2.3 curdom = DOM1
        curdom = riscv::DOM1;
        #5ns; // No exception
        assert(decoded_instruction.ex.valid == 0);

        // 2.4 curdom = DOM2
        curdom = riscv::DOM2;
        #5ns; // Exception raised!
        assert(decoded_instruction.ex.valid == 1);
        assert(decoded_instruction.ex.cause == riscv::ILLEGAL_INSTR);

        // -------------------------------
        // 3rd test batch: lb1 decoding
        instruction = 32'h0283038b; // lb1 t2,40(t1)

        // 3.1 curdom = DOMI
        curdom = riscv::DOMI;
        #5ns;
        assert(decoded_instruction.op == LB1);               // Correct opcode
        assert(decoded_instruction.ex.valid == 0);           // No exception
        assert(decoded_instruction.code_dom == riscv::DOM1); // Executed from domain 1
        assert(decoded_instruction.data_dom == riscv::DOM1); // Accesses domain 1
        assert(decoded_instruction.chg_dom  == 0);           // Should not change dom

        // 3.2 curdom = DOM0
        curdom = riscv::DOM0;
        #5ns; // Exception raised!
        assert(decoded_instruction.ex.valid == 1);
        assert(decoded_instruction.ex.cause == riscv::ILLEGAL_INSTR);

        // 3.3 curdom = DOM1
        curdom = riscv::DOM1;
        #5ns; // No exception
        assert(decoded_instruction.ex.valid == 0);

        // 3.4 curdom = DOM2
        curdom = riscv::DOM2;
        #5ns; // Exception raised!
        assert(decoded_instruction.ex.valid == 1);
        assert(decoded_instruction.ex.cause == riscv::ILLEGAL_INSTR);

        // -------------------------------
        // 4th test batch: sb1 decoding
        instruction = 32'h0273042b; // sb1 t2,40(t1)

        // 4.1 curdom = DOMI
        curdom = riscv::DOMI;
        #5ns;
        assert(decoded_instruction.op == SB1);               // Correct opcode
        assert(decoded_instruction.ex.valid == 0);           // No exception
        assert(decoded_instruction.code_dom == riscv::DOM1); // Executed from domain 1
        assert(decoded_instruction.data_dom == riscv::DOM1); // Accesses domain 1
        assert(decoded_instruction.chg_dom  == 0);           // Should not change dom

        // 4.2 curdom = DOM0
        curdom = riscv::DOM0;
        #5ns; // Exception raised!
        assert(decoded_instruction.ex.valid == 1);
        assert(decoded_instruction.ex.cause == riscv::ILLEGAL_INSTR);

        // 4.3 curdom = DOM1
        curdom = riscv::DOM1;
        #5ns; // No exception
        assert(decoded_instruction.ex.valid == 0);

        // 4.4 curdom = DOM2
        curdom = riscv::DOM2;
        #5ns; // Exception raised!
        assert(decoded_instruction.ex.valid == 1);
        assert(decoded_instruction.ex.cause == riscv::ILLEGAL_INSTR);

        // -------------------------------
        // 5th test batch: lst decoding
        instruction = 32'h0283738b; // lst t2,40(t1)

        // 5.1 curdom = DOMI
        curdom = riscv::DOMI;
        #5ns;
        assert(decoded_instruction.op == LST);               // Correct opcode
        assert(decoded_instruction.ex.valid == 0);           // No exception
        assert(decoded_instruction.code_dom == riscv::DOM1); // Executed from domain 1
        assert(decoded_instruction.data_dom == riscv::DOM2); // Accesses domain 2
        assert(decoded_instruction.chg_dom  == 0);           // Should not change dom

        // 5.2 curdom = DOM0
        curdom = riscv::DOM0;
        #5ns; // Exception raised!
        assert(decoded_instruction.ex.valid == 1);
        assert(decoded_instruction.ex.cause == riscv::ILLEGAL_INSTR);

        // 5.3 curdom = DOM1
        curdom = riscv::DOM1;
        #5ns; // No exception
        assert(decoded_instruction.ex.valid == 0);

        // 5.4 curdom = DOM2
        curdom = riscv::DOM2;
        #5ns; // Exception raised!
        assert(decoded_instruction.ex.valid == 1);
        assert(decoded_instruction.ex.cause == riscv::ILLEGAL_INSTR);

        // -------------------------------
        // 6th test batch: sst decoding
        instruction = 32'h028373ab; // sst t2,40(t1)

        // 6.1 curdom = DOMI
        curdom = riscv::DOMI;
        #5ns;
        assert(decoded_instruction.op == SST);               // Correct opcode
        assert(decoded_instruction.ex.valid == 0);           // No exception
        assert(decoded_instruction.code_dom == riscv::DOM1); // Executed from domain 1
        assert(decoded_instruction.data_dom == riscv::DOM2); // Accesses domain 2
        assert(decoded_instruction.chg_dom  == 0);           // Should not change dom

        // 6.2 curdom = DOM0
        curdom = riscv::DOM0;
        #5ns; // Exception raised!
        assert(decoded_instruction.ex.valid == 1);
        assert(decoded_instruction.ex.cause == riscv::ILLEGAL_INSTR);

        // 6.3 curdom = DOM1
        curdom = riscv::DOM1;
        #5ns; // No exception
        assert(decoded_instruction.ex.valid == 0);

        // 6.4 curdom = DOM2
        curdom = riscv::DOM2;
        #5ns; // Exception raised!
        assert(decoded_instruction.ex.valid == 1);
        assert(decoded_instruction.ex.cause == riscv::ILLEGAL_INSTR);

        // -------------------------------
        // 7th test batch: chdom decoding
        instruction = 32'h0003105b; // chdom

        // 7.1 curdom = DOMI
        curdom = riscv::DOMI;
        #5ns;
        assert(decoded_instruction.op == CHDOM);             // Correct opcode
        assert(decoded_instruction.ex.valid == 0);           // No exception
        assert(decoded_instruction.code_dom == riscv::DOM0); // Executed from domain 0
        assert(decoded_instruction.data_dom == riscv::DOM1); // Accesses domain 1
        assert(decoded_instruction.chg_dom  == 1);           // Should change dom

        // 7.2 curdom = DOM0
        curdom = riscv::DOM0;
        #5ns; // No exception
        assert(decoded_instruction.ex.valid == 0);

        // 7.3 curdom = DOM1
        curdom = riscv::DOM1;
        #5ns; // Exception raised!
        assert(decoded_instruction.ex.valid == 1);
        assert(decoded_instruction.ex.cause == riscv::ILLEGAL_INSTR);

        // 7.4 curdom = DOM2
        curdom = riscv::DOM2;
        #5ns; // Exception raised!
        assert(decoded_instruction.ex.valid == 1);
        assert(decoded_instruction.ex.cause == riscv::ILLEGAL_INSTR);

        // -------------------------------
        // 8th test batch: retdom decoding
        instruction = 32'h0003105b; // retdom

        // 8.1 curdom = DOMI
        curdom = riscv::DOMI;
        #5ns;
        assert(decoded_instruction.op == CHDOM);             // Correct opcode
        assert(decoded_instruction.ex.valid == 0);           // No exception
        assert(decoded_instruction.code_dom == riscv::DOM1); // Executed from domain 0
        assert(decoded_instruction.data_dom == riscv::DOM0); // Accesses domain 1
        assert(decoded_instruction.chg_dom  == 1);           // Should change dom

        // 8.2 curdom = DOM0
        curdom = riscv::DOM0;
        #5ns; // Exception raised!
        assert(decoded_instruction.ex.valid == 1);
        assert(decoded_instruction.ex.cause == riscv::ILLEGAL_INSTR);

        // 8.3 curdom = DOM1
        curdom = riscv::DOM1;
        #5ns; // No exception
        assert(decoded_instruction.ex.valid == 0);

        // 8.4 curdom = DOM2
        curdom = riscv::DOM2;
        #5ns; // Exception raised!
        assert(decoded_instruction.ex.valid == 1);
        assert(decoded_instruction.ex.cause == riscv::ILLEGAL_INSTR);
    end
endmodule