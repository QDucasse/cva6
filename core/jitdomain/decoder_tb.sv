// Author: Quentin Ducasse, ENSTA Bretagne
// Date: 10.10.2023
// Description: Self-contained testbench for the decoder, modeled after the pmp one

import ariane_pkg::*;

module decoder_tb;
    timeunit 1ns;
    timeprecision 1ps;

    localparam config_pkg::cva6_cfg_t CVA6Cfg = build_config_pkg::build_config(cva6_config_pkg::cva6_cfg);

    // Pipeline types, mirrored from cva6.sv
    localparam type branchpredict_sbe_t = struct packed {
      logic                    valid;            // valid control flow prediction
      cf_t                     cf;               // type of control flow prediction
      logic [CVA6Cfg.VLEN-1:0] predict_address;  // target address at which to jump, or not
    };
    localparam type exception_t = struct packed {
      logic [CVA6Cfg.XLEN-1:0] cause;  // cause of exception
      logic [CVA6Cfg.XLEN-1:0] tval;  // additional information of causing exception (e.g.: instruction causing it),
      // address of LD/ST fault
      logic [CVA6Cfg.GPLEN-1:0] tval2;  // additional information when the causing exception in a guest exception
      logic [31:0] tinst;  // transformed instruction information
      logic gva;  // signals when a guest virtual address is written to tval
      logic valid;
      //timing of exception, timing = 0 : break immediately or timing = 1 break immediatemy AFTER (let current instruction commit but only this one)
      logic timing;
    };
    localparam type scoreboard_entry_t = struct packed {
      logic [CVA6Cfg.VLEN-1:0] pc;  // PC of instruction
      logic [CVA6Cfg.TRANS_ID_BITS-1:0] trans_id;      // this can potentially be simplified, we could index the scoreboard entry
      // with the transaction id in any case make the width more generic
      fu_t fu;  // functional unit to use
      fu_op op;  // operation to perform in each functional unit
      logic [REG_ADDR_SIZE-1:0] rs1;  // register source address 1
      logic [REG_ADDR_SIZE-1:0] rs2;  // register source address 2
      logic [REG_ADDR_SIZE-1:0] rd;  // register destination address
      logic [CVA6Cfg.XLEN-1:0] result;  // for unfinished instructions this field also holds the immediate,
      // for unfinished floating-point that are partly encoded in rs2, this field also holds rs2
      // for unfinished floating-point fused operations (FMADD, FMSUB, FNMADD, FNMSUB)
      // this field holds the address of the third operand from the floating-point register file
      logic valid;  // is the result valid
      logic use_imm;  // should we use the immediate as operand b?
      logic use_zimm;  // use zimm as operand a
      logic use_pc;  // set if we need to use the PC as operand a, PC from exception
      exception_t ex;  // exception has occurred
      branchpredict_sbe_t bp;  // branch predict scoreboard data structure
      logic                     is_compressed; // signals a compressed instructions, we need this information at the commit stage if
                                               // we want jump accordingly e.g.: +4, +2
      logic is_macro_instr;  // is an instruction executed as predefined sequence of instructions called macro definition
      logic is_last_macro_instr;  // is last decoded 32bit instruction of macro definition
      logic is_double_rd_macro_instr;  // is double move decoded 32bit instruction of macro definition
      logic vfp;  // is this a vector floating-point instruction?
      logic is_zcmt;  //is a zcmt instruction
      // JITDomain related fields
      riscv::dmp_domain_t target_dom;  // associated target domain (should access this domain - through data or fetch)
      logic chg_dom;  // flag to change internal state (should change domain)
    };
    localparam type irq_ctrl_t = struct packed {
      logic [CVA6Cfg.XLEN-1:0] mie;
      logic [CVA6Cfg.XLEN-1:0] mip;
      logic [CVA6Cfg.XLEN-1:0] mideleg;
      logic [CVA6Cfg.XLEN-1:0] hideleg;
      logic                    sie;
      logic                    global_enable;
    };

    localparam type interrupts_t = struct packed {
      logic [CVA6Cfg.XLEN-1:0] S_SW;
      logic [CVA6Cfg.XLEN-1:0] VS_SW;
      logic [CVA6Cfg.XLEN-1:0] M_SW;
      logic [CVA6Cfg.XLEN-1:0] S_TIMER;
      logic [CVA6Cfg.XLEN-1:0] VS_TIMER;
      logic [CVA6Cfg.XLEN-1:0] M_TIMER;
      logic [CVA6Cfg.XLEN-1:0] S_EXT;
      logic [CVA6Cfg.XLEN-1:0] VS_EXT;
      logic [CVA6Cfg.XLEN-1:0] M_EXT;
      logic [CVA6Cfg.XLEN-1:0] HS_EXT;
    };

    // Inputs - Testing
    logic [CVA6Cfg.VLEN-1:0] pc;
    logic [31:0]            instruction;
    riscv::dmp_domain_t     curdom;
    // Outputs - Asserting
    scoreboard_entry_t      decoded_instruction;
    logic [31:0]            orig_instr;
    logic                   is_control_flow_instr;

    decoder #(
        .CVA6Cfg             ( CVA6Cfg             ),
        .branchpredict_sbe_t ( branchpredict_sbe_t ),
        .exception_t         ( exception_t         ),
        .irq_ctrl_t          ( irq_ctrl_t          ),
        .scoreboard_entry_t  ( scoreboard_entry_t  ),
        .interrupts_t        ( interrupts_t        ),
        .INTERRUPTS          ( '0                  )
    ) i_decoder(
        // Debug
        .debug_req_i                ( '0                     ),
        // Compressed instructions
        .is_compressed_i            ( '0                     ),
        .compressed_instr_i         ( '0                     ),
        .is_illegal_i               ( '0                     ),
        // Macro / Zcmt instructions
        .is_macro_instr_i           ( '0                     ),
        .is_last_macro_instr_i      ( '0                     ),
        .is_double_rd_macro_instr_i ( '0                     ),
        .is_zcmt_i                  ( '0                     ),
        .jump_address_i             ( '0                     ),
        // Branch predict
        .branch_predict_i           ( '0                     ),
        // Exception during fetch
        .ex_i                       ( '0                     ),
        .irq_i                      ( '0                     ),
        .irq_ctrl_i                 ( '0                     ),
        .priv_lvl_i                 ( riscv::PRIV_LVL_U      ),
        .v_i                        ( '0                     ),
        .debug_mode_i               ( '0                     ),
        .fs_i                       ( riscv::Off             ),
        .vfs_i                      ( riscv::Off             ),
        .frm_i                      ( '0                     ),
        .vs_i                       ( riscv::Off             ),
        .tvm_i                      ( '0                     ),
        .tw_i                       ( '0                     ),
        .vtw_i                      ( '0                     ),
        .tsr_i                      ( '0                     ),
        .hu_i                       ( '0                     ),
        .mcbie_i                    ( riscv::CBIE_ILLEGAL    ),
        .scbie_i                    ( riscv::CBIE_ILLEGAL    ),
        .hcbie_i                    ( riscv::CBIE_ILLEGAL    ),
        .mcbcfe_i                   ( '0                     ),
        .scbcfe_i                   ( '0                     ),
        .hcbcfe_i                   ( '0                     ),
        .sdtrig_decoder_action_i    ( '0                     ),
        // Testing signal
        .pc_i                       ( pc                     ),
        .instruction_i              ( instruction            ),
        .curdom_i                   ( curdom                 ),
        .instruction_o              ( decoded_instruction    ),
        .orig_instr_o               ( orig_instr             ),
        .is_control_flow_instr_o    ( is_control_flow_instr  )
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
        assert(decoded_instruction.ex.valid == 0);           // No exception - Executed from domain 0/1
        assert(decoded_instruction.target_dom == riscv::DOM0); // Accesses domain 0
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
        assert(decoded_instruction.ex.valid == 0);           // No exception - Executed from domain 0/1
        assert(decoded_instruction.target_dom == riscv::DOM0); // Accesses domain 0
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
        assert(decoded_instruction.ex.valid == 0);           // No exception - Executed from domain 1
        assert(decoded_instruction.target_dom == riscv::DOM1); // Accesses domain 1
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
        assert(decoded_instruction.ex.valid == 0);           // No exception - Executed from domain 1
        assert(decoded_instruction.target_dom == riscv::DOM1); // Accesses domain 1
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
        assert(decoded_instruction.ex.valid == 0);           // No exception - Executed from domain 1
        assert(decoded_instruction.target_dom == riscv::DOM2); // Accesses domain 2
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
        assert(decoded_instruction.ex.valid == 0);           // No exception - Executed from domain 1
        assert(decoded_instruction.target_dom == riscv::DOM2); // Accesses domain 2
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
        assert(decoded_instruction.ex.valid == 0);           // No exception - Executed from domain 0
        assert(decoded_instruction.target_dom == riscv::DOM1); // Accesses domain 1
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
        instruction = 32'h0000805b; // retdom

        // 8.1 curdom = DOMI
        curdom = riscv::DOMI;
        #5ns;
        assert(decoded_instruction.op == RETDOM);            // Correct opcode
        assert(decoded_instruction.ex.valid == 0);           // No exception - Executed from domain 0
        assert(decoded_instruction.target_dom == riscv::DOM0); // Accesses domain 1
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