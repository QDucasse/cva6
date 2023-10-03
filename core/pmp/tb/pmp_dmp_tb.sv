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


// Update with jitdomain tests:
// Author - pcotret
// - V2023.09.28 : testing a single PMP/DMP entry with PMP in NAPOT address mode. Only DMP rights are tested.
//



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
    riscv::pmpcfg_t [NR_ENTRIES-1:0] conf_pmp;
    riscv::dmpcfg_t [NR_ENTRIES-1:0] conf_dmp;
    riscv::dmp_domain_t expected_domain;



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
        .addr_i         ( addr              ),
        .access_type_i  ( access_type       ),
        .priv_lvl_i     ( riscv::PRIV_LVL_U ),
        .expected_dom_i ( expected_domain   ),
        .conf_addr_i    ( conf_addr         ),
        .pmpconf_i      ( conf_pmp          ),
        .dmpconf_i      ( conf_dmp          ),
        .allow_o        ( allow             )
    );
    

    initial begin
        // set pmp to disabled initially
      conf_pmp[0].addr_mode = riscv::OFF;
        conf_dmp[0].domain = riscv::DOMI;

        // test address to read
        addr = 16'b00011001_10111010;
        access_type = riscv::ACCESS_READ;

        // 1st test batch: PMP allow access
        base = 16'b00011001_00000000;
        size = 8;
        conf_addr[0] = P#(.WIDTH(WIDTH), .PMP_LEN(PMP_LEN))::base_to_conf(base, size);
        conf_pmp[0].addr_mode = riscv::NAPOT;
        conf_pmp[0].access_type = riscv::ACCESS_READ | riscv::ACCESS_WRITE | riscv::ACCESS_EXEC;

        // 1.1 curdom = DOM0 | dmpcfg = DOM0
        expected_domain=riscv::DOM0;
        conf_dmp[0].domain=riscv::DOM0;
        #5ns;
        assert(allow == 1);
        // 1.2 curdom = DOM0 | dmpcfg = DOM1
        conf_dmp[0].domain=riscv::DOM1;
        #5ns;
        assert(allow == 0);
        // 1.3 curdom = DOM0 | dmpcfg = DOM2
        conf_dmp[0].domain=riscv::DOM2;
        #5ns;
        assert(allow == 0);
        // 1.4 curdom = DOM0 | dmpcfg = DOMI
        conf_dmp[0].domain=riscv::DOMI;
        #5ns;
        assert(allow == 1);

        // 1.5 curdom = DOM1 | dmpcfg = DOM0
        expected_domain=riscv::DOM1;
        conf_dmp[0].domain=riscv::DOM0;
        #5ns;
        assert(allow == 0);
        // 1.6 curdom = DOM1 | dmpcfg = DOM1
        conf_dmp[0].domain=riscv::DOM1;
        #5ns;
        assert(allow == 1);
        // 1.7 curdom = DOM1 | dmpcfg = DOM2
        conf_dmp[0].domain=riscv::DOM2;
        #5ns;
        assert(allow == 0);
        // 1.8 curdom = DOM1 | dmpcfg = DOMI
        conf_dmp[0].domain=riscv::DOMI;
        #5ns;
        assert(allow == 1);

        // 1.9 curdom = DOMI | dmpcfg = DOM0
        expected_domain=riscv::DOMI;
        conf_dmp[0].domain=riscv::DOM0;
        #5ns;
        assert(allow == 1);
        // 1.10 curdom = DOMI | dmpcfg = DOM1
        conf_dmp[0].domain=riscv::DOM1;
        #5ns;
        assert(allow == 1);
        // 1.11 curdom = DOMI | dmpcfg = DOM2
        conf_dmp[0].domain=riscv::DOM2;
        #5ns;
        assert(allow == 1);
        // 1.12 curdom = DOMI | dmpcfg = DOMI
        conf_dmp[0].domain=riscv::DOMI;
        #5ns;
        assert(allow == 1);

        // 2nd test batch: PMP does not allow access
        conf_addr[0] = P#(.WIDTH(WIDTH), .PMP_LEN(PMP_LEN))::base_to_conf(base, size);
        conf_pmp[0].addr_mode = riscv::NAPOT;
        conf_pmp[0].access_type = riscv::ACCESS_EXEC; // No read access

        // 2.1 curdom = DOM0 | dmpcfg = DOM0
        expected_domain=riscv::DOM0;
        conf_dmp[0].domain=riscv::DOM0;
        #5ns;
        assert(allow == 0);
        // 2.2 curdom = DOM0 | dmpcfg = DOM1
        conf_dmp[0].domain=riscv::DOM1;
        #5ns;
        assert(allow == 0);
        // 2.3 curdom = DOM0 | dmpcfg = DOM2
        conf_dmp[0].domain=riscv::DOM2;
        #5ns;
        assert(allow == 0);
        // 2.4 curdom = DOM0 | dmpcfg = DOMI
        conf_dmp[0].domain=riscv::DOMI;
        #5ns;
        assert(allow == 0);

        // 2.5 curdom = DOM1 | dmpcfg = DOM0
        expected_domain=riscv::DOM1;
        conf_dmp[0].domain=riscv::DOM0;
        #5ns;
        assert(allow == 0);
        // 2.6 curdom = DOM1 | dmpcfg = DOM1
        conf_dmp[0].domain=riscv::DOM1;
        #5ns;
        assert(allow == 0);
        // 2.7 curdom = DOM1 | dmpcfg = DOM2
        conf_dmp[0].domain=riscv::DOM2;
        #5ns;
        assert(allow == 0);
        // 2.8 curdom = DOM1 | dmpcfg = DOMI
        conf_dmp[0].domain=riscv::DOMI;
        #5ns;
        assert(allow == 0);

        // 2.9 curdom = DOMI | dmpcfg = DOM0
        expected_domain=riscv::DOMI;
        conf_dmp[0].domain=riscv::DOM0;
        #5ns;
        assert(allow == 0);
        // 2.10 curdom = DOMI | dmpcfg = DOM1
        conf_dmp[0].domain=riscv::DOM1;
        #5ns;
        assert(allow == 0);
        // 2.11 curdom = DOMI | dmpcfg = DOM2
        conf_dmp[0].domain=riscv::DOM2;
        #5ns;
        assert(allow == 0);
        // 2.12 curdom = DOMI | dmpcfg = DOMI
        conf_dmp[0].domain=riscv::DOMI;
        #5ns;
        assert(allow == 0);
    end
endmodule
