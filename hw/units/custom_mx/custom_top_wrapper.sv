`include "simplyv_axi.svh"
`include "simplyv_mem.svh"

module custom_top_wrapper #(
    parameter LOCAL_DATA_WIDTH = 32,
    parameter LOCAL_ADDR_WIDTH = 32
) (
    input  logic                 clk_i,
    input  logic                 rst_ni,
    input  logic [31:0]          hart_id_i,
    input  logic [31:0]          boot_addr_i,
    input  logic                 irq_software_i,
    input  logic                 irq_timer_i,
    input  logic                 irq_external_i,
    input  logic [14:0]          irq_fast_i,
    input  logic                 irq_nm_i,
    input  logic                 debug_req_i,
    `DEFINE_MEM_MASTER_PORTS(instr, LOCAL_DATA_WIDTH, LOCAL_ADDR_WIDTH),
    `DEFINE_MEM_MASTER_PORTS(data,  LOCAL_DATA_WIDTH, LOCAL_ADDR_WIDTH)
);
    // The MX core has a single unified memory port; route everything through
    // the data master and idle the instruction master.
    assign instr_mem_req   = 1'b0;
    assign instr_mem_addr  = '0;
    assign instr_mem_wdata = '0;
    assign instr_mem_we    = 1'b0;
    assign instr_mem_be    = '0;

    // core <-> bridge wires
    logic        c_read, c_read_block, c_read_vector, c_write, c_valid, c_wack, c_wait;
    logic [31:0] c_addr, c_wdata, c_rdata;
    logic [3:0]  c_be;
    logic [5:0]  c_vl;

    CORE #(.ID(0)) u_core (
        .clk_i        ( clk_i ),
        .rst_i        ( rst_ni ),            // CORE resets on if(~rst_i): active-low; HAZARDS.v uses if(rst_i) but receives same port — upstream inconsistency, port polarity is active-low
        .clk_gated_i  ( clk_i ),             // no gating for bring-up
        .irq_software_i ( irq_software_i ),  // CLINT MSIP
        .irq_timer_i    ( irq_timer_i ),     // CLINT MTIP
        .irq_external_i ( irq_external_i ),  // PLIC MEIP
        .addr_o       ( c_addr ),
        .data_o       ( c_wdata ),
        .read_o       ( c_read ),
        .read_block_o ( c_read_block ),
        .read_vector_o( c_read_vector ),
        .write_o      ( c_write ),
        .be_o         ( c_be ),
        .vl_o         ( c_vl ),
        .valid_i      ( c_valid ),
        .wack_i       ( c_wack ),            // write-acknowledge (separate from read-data valid)
        .data_i       ( c_rdata )
    );

    mx_mem_bridge #(.ADDR_WIDTH(LOCAL_ADDR_WIDTH), .DATA_WIDTH(LOCAL_DATA_WIDTH)) u_bridge (
        .clk_i(clk_i), .rst_ni(rst_ni),
        .core_read_i(c_read), .core_read_block_i(c_read_block),
        .core_read_vector_i(c_read_vector), .core_write_i(c_write),
        .core_addr_i(c_addr), .core_wdata_i(c_wdata), .core_be_i(c_be),
        .core_vl_i(c_vl[4:0]), .core_valid_o(c_valid), .core_wack_o(c_wack), .core_rdata_o(c_rdata),
        .core_wait_o(c_wait),
        .m_mem_req(data_mem_req), .m_mem_gnt(data_mem_gnt), .m_mem_valid(data_mem_valid),
        .m_mem_addr(data_mem_addr), .m_mem_rdata(data_mem_rdata), .m_mem_wdata(data_mem_wdata),
        .m_mem_we(data_mem_we), .m_mem_be(data_mem_be), .m_mem_error(data_mem_error)
    );

    // bring-up tie-offs (irq_software/timer/external now wired to the CORE)
    logic _unused = &{1'b0, irq_fast_i, irq_nm_i, debug_req_i, hart_id_i, boot_addr_i, c_wait};
endmodule
