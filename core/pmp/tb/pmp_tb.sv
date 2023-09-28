// Copyright 2019 ETH Zurich and University of Bologna.
// Copyright and related rights are licensed under the Solderpad Hardware
// License, Version 0.51 (the "License"); you may not use this file except in
// compliance with the License.  You may obtain a copy of the License at
// http://solderpad.org/licenses/SHL-0.51. Unless required by applicable law
// or agreed to in writing, software, hardware and materials distributed under
// this License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
// CONDITIONS OF ANY KIND, either express or implied. See the License for the
// specific language governing permissions and limitations under the License.
//
// Author: Moritz Schneider, ETH Zurich
// Date: 2.10.2019
// Description: 

/* Updates for @QDucasse work:
 * - V2023.09.28 : testing a single PMP/DMP entry with PMP in NAPOT address mode. Only DMP rights are tested.
 */

import tb_pkg::*;

module pmp_tb;
    timeunit 1ns;
    timeprecision 1ps;

    localparam int unsigned WIDTH = 16;
    localparam int unsigned PMP_LEN = 13;
    localparam int unsigned NR_ENTRIES = 1;

    logic [WIDTH-1:0] addr;
    riscv::pmp_access_t access_type;
    
    // Configuration
    logic [NR_ENTRIES-1:0][PMP_LEN-1:0] conf_addr;
    riscv::pmpcfg_t [NR_ENTRIES-1:0] conf;
    riscv::dmpcfg_t [NR_ENTRIES-1:0] confdmp;
    riscv::dmp_domain_t current_domain;

    // Output
    logic allow;

    // helper signals
    logic[WIDTH-1:0] base;
    int unsigned size;

    pmp #(
        .PLEN(WIDTH),
        .PMP_LEN(PMP_LEN),
        .NR_ENTRIES(NR_ENTRIES)
    ) i_pmp(
        .addr_i        ( addr              ),
        .access_type_i ( access_type       ),
        .priv_lvl_i    ( riscv::PRIV_LVL_U ),
        .curdom_i      ( current_domain    ),
        .conf_addr_i   ( conf_addr         ),
        .pmpconf_i     ( conf              ),
        .dmpconf_i     ( confdmp           ),
        .allow_o       ( allow             )
    );
    

    initial begin
        // set all pmps to disabled initially
        for (int i = 0; i < NR_ENTRIES; i++) begin
            conf[i].addr_mode = riscv::OFF;
        end
        // request to test
        addr = 16'b00011001_10111010;
        access_type = riscv::ACCESS_READ;
        // PMP entry settings
        base = 16'b00011001_00000000;
        size = 8;
        conf_addr[0] = P#(.WIDTH(WIDTH), .PMP_LEN(PMP_LEN))::base_to_conf(base, size);
        conf[0].addr_mode = riscv::NAPOT;
        conf[0].access_type = riscv::ACCESS_READ | riscv::ACCESS_WRITE | riscv::ACCESS_EXEC;

        // Current domain = DOM0 | dmpcfg = DOM0
        current_domain=riscv::DOM0;
        for (int i=0;i<NR_ENTRIES;i++) begin
            confdmp[i].domain=riscv::DOM0;
        end
        #5ns;
        assert(allow == 1);
        // Current domain = DOM0 | dmpcfg = DOM1        
        current_domain=riscv::DOM0;
        for (int i=0;i<NR_ENTRIES;i++) begin
            confdmp[i].domain=riscv::DOM1;
        end
        #5ns;
        assert(allow == 0);
        // Current domain = DOM0 | dmpcfg = DOM2
                current_domain=riscv::DOM0;
        for (int i=0;i<NR_ENTRIES;i++) begin
            confdmp[i].domain=riscv::DOM2;
        end
        #5ns;
        assert(allow == 0);
        // Current domain = DOM0 | dmpcfg = DOMI
        current_domain=riscv::DOM0;
        for (int i=0;i<NR_ENTRIES;i++) begin
            confdmp[i].domain=riscv::DOMI;
        end
        #5ns;
        assert(allow == 1);
        // Current domain = DOM1 | dmpcfg = DOM0
        current_domain=riscv::DOM1;
        for (int i=0;i<NR_ENTRIES;i++) begin
            confdmp[i].domain=riscv::DOM0;
        end
        #5ns;
        assert(allow == 0);
        // Current domain = DOM1 | dmpcfg = DOM1
        current_domain=riscv::DOM1;
        for (int i=0;i<NR_ENTRIES;i++) begin
            confdmp[i].domain=riscv::DOM1;
        end
        #5ns;
        assert(allow == 1);
        // Current domain = DOM1 | dmpcfg = DOM2
        current_domain=riscv::DOM1;
        for (int i=0;i<NR_ENTRIES;i++) begin
            confdmp[i].domain=riscv::DOM2;
        end
        #5ns;
        assert(allow == 0);
        // Current domain = DOM1 | dmpcfg = DOMI
        current_domain=riscv::DOM1;
        for (int i=0;i<NR_ENTRIES;i++) begin
            confdmp[i].domain=riscv::DOMI;
        end
        #5ns;
        assert(allow == 1);
        // Current domain = DOM2 | dmpcfg = DOM0
        current_domain=riscv::DOM2;
        for (int i=0;i<NR_ENTRIES;i++) begin
            confdmp[i].domain=riscv::DOM0;
        end
        #5ns;
        assert(allow == 0);
        // Current domain = DOM2 | dmpcfg = DOM1
        current_domain=riscv::DOM1;
        for (int i=0;i<NR_ENTRIES;i++) begin
            confdmp[i].domain=riscv::DOM1;
        end
        #5ns;
        assert(allow == 0);
        // Current domain = DOM2 | dmpcfg = DOM2
        current_domain=riscv::DOM1;
        for (int i=0;i<NR_ENTRIES;i++) begin
            confdmp[i].domain=riscv::DOM2;
        end
        #5ns;
        assert(allow == 1);
        // Current domain = DOM2 | dmpcfg = DOMI
        current_domain=riscv::DOM1;
        for (int i=0;i<NR_ENTRIES;i++) begin
            confdmp[i].domain=riscv::DOMI;
        end
        #5ns;
        assert(allow == 1);
        // Current domain = DOMI| dmpcfg = DOM0
        current_domain=riscv::DOMI;
        for (int i=0;i<NR_ENTRIES;i++) begin
            confdmp[i].domain=riscv::DOM0;
        end
        #5ns;
        assert(allow == 1);
        // Current domain = DOMI | dmpcfg = DOM1
        current_domain=riscv::DOMI;
        for (int i=0;i<NR_ENTRIES;i++) begin
            confdmp[i].domain=riscv::DOM1;
        end
        #5ns;
        assert(allow == 1);
        // Current domain = DOMI | dmpcfg = DOM2
        current_domain=riscv::DOMI;
        for (int i=0;i<NR_ENTRIES;i++) begin
            confdmp[i].domain=riscv::DOM2;
        end
        #5ns;
        assert(allow == 1);
        // Current domain = DOMI | dmpcfg = DOMI
        current_domain=riscv::DOMI;
        for (int i=0;i<NR_ENTRIES;i++) begin
            confdmp[i].domain=riscv::DOMI;
        end
        #5ns;
        assert(allow == 1);
    end
endmodule