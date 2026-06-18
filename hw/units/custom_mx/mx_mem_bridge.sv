// MX (VC0) memory-protocol bridge: translates the core's word/block/vector
// read + word/block write protocol onto a Simply-V mem-bus master.
module mx_mem_bridge #(
    parameter int ADDR_WIDTH  = 32,
    parameter int DATA_WIDTH  = 32,
    parameter int BLOCK_WORDS = 16
) (
    input  logic                    clk_i,
    input  logic                    rst_ni,
    // MX core side
    input  logic                    core_read_i,
    input  logic                    core_read_block_i,
    input  logic                    core_read_vector_i,
    input  logic                    core_write_i,
    input  logic [ADDR_WIDTH-1:0]   core_addr_i,
    input  logic [DATA_WIDTH-1:0]   core_wdata_i,
    input  logic [DATA_WIDTH/8-1:0] core_be_i,
    input  logic [4:0]              core_vl_i,
    output logic                    core_valid_o,
    output logic [DATA_WIDTH-1:0]   core_rdata_o,
    output logic                    core_wait_o,
    // mem-bus master side
    output logic                    m_mem_req,
    input  logic                    m_mem_gnt,
    input  logic                    m_mem_valid,
    output logic [ADDR_WIDTH-1:0]   m_mem_addr,
    input  logic [DATA_WIDTH-1:0]   m_mem_rdata,
    output logic [DATA_WIDTH-1:0]   m_mem_wdata,
    output logic                    m_mem_we,
    output logic [DATA_WIDTH/8-1:0] m_mem_be,
    input  logic                    m_mem_error
);
    typedef enum logic [2:0] {IDLE, RD_REQ, RD_WAIT, WR_REQ} state_t;
    state_t       state;
    logic [ADDR_WIDTH-1:0] base_q, addr_q;
    logic [5:0]   total_q, cnt_q;          // up to 32 (MVL) or 16 (block)
    logic         is_write_q;

    assign core_wait_o = (state != IDLE);

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            state <= IDLE; cnt_q <= 0; total_q <= 0; is_write_q <= 0;
            m_mem_req <= 0; m_mem_we <= 0; core_valid_o <= 0;
        end else begin
            core_valid_o <= 1'b0;
            unique case (state)
            IDLE: begin
                m_mem_req <= 1'b0;
                if (core_read_i || core_read_block_i || core_read_vector_i) begin
                    base_q     <= core_addr_i;  addr_q <= core_addr_i;  cnt_q <= 0;
                    total_q    <= core_read_block_i  ? BLOCK_WORDS[5:0] :
                                  core_read_vector_i ? {1'b0, core_vl_i} : 6'd1;
                    is_write_q <= 1'b0;
                    m_mem_addr <= core_addr_i; m_mem_we <= 1'b0; m_mem_req <= 1'b1;
                    state      <= RD_REQ;
                end else if (core_write_i) begin
                    m_mem_addr <= core_addr_i; m_mem_wdata <= core_wdata_i;
                    m_mem_be   <= core_be_i;   m_mem_we <= 1'b1; m_mem_req <= 1'b1;
                    state      <= WR_REQ;
                end
            end
            RD_REQ: if (m_mem_gnt) begin m_mem_req <= 1'b0; state <= RD_WAIT; end
            RD_WAIT: if (m_mem_valid) begin
                core_rdata_o <= m_mem_rdata; core_valid_o <= 1'b1;
                if (cnt_q + 1 == total_q) begin state <= IDLE; end
                else begin
                    cnt_q      <= cnt_q + 1;
                    addr_q     <= addr_q + (DATA_WIDTH/8);
                    m_mem_addr <= addr_q + (DATA_WIDTH/8);
                    m_mem_we   <= 1'b0; m_mem_req <= 1'b1; state <= RD_REQ;
                end
            end
            WR_REQ: if (m_mem_gnt) begin m_mem_req <= 1'b0; m_mem_we <= 1'b0; state <= IDLE; end
            default: state <= IDLE;
            endcase
        end
    end
endmodule
