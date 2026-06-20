// MX (VC0) memory-protocol bridge: translates the core's word/block/vector
// read + word/block write protocol onto a Simply-V mem-bus master.
//
// Protocol note: MEMACCESS fires core_read_block_i / core_read_i / core_write_i
// as single-cycle pulses (the trigger window collapses after one clock).  The
// bridge may be busy (RD_REQ / RD_WAIT / WR_REQ) when a new request arrives, so
// we latch every incoming request immediately into pending flops and drain them
// in IDLE order (read types before writes; block/vector before word).  Without
// the latch the bridge misses any request that arrives while it is not in IDLE,
// which causes a permanent L1D block-fill deadlock.
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
    output logic                    core_valid_o,   // READ-data valid (one pulse per read word)
    output logic                    core_wack_o,    // WRITE acknowledge (one pulse per completed write)
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

    // Pending-request latches: capture any request that arrives while the bridge
    // is busy and hold it until the bridge returns to IDLE.
    logic                    pend_read_q,  pend_block_q,  pend_vector_q,  pend_write_q;
    logic [ADDR_WIDTH-1:0]   pend_addr_q;
    logic [DATA_WIDTH-1:0]   pend_wdata_q;
    logic [DATA_WIDTH/8-1:0] pend_be_q;
    logic [4:0]              pend_vl_q;

    assign core_wait_o = (state != IDLE);

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            state        <= IDLE;
            cnt_q        <= 0; total_q <= 0;
            m_mem_req    <= 0; m_mem_we <= 0; core_valid_o <= 0; core_wack_o <= 0;
            pend_read_q  <= 0; pend_block_q <= 0;
            pend_vector_q<= 0; pend_write_q <= 0;
            pend_addr_q  <= '0; pend_wdata_q <= '0;
            pend_be_q    <= '0; pend_vl_q    <= '0;
        end else begin
            core_valid_o <= 1'b0;
            core_wack_o  <= 1'b0;

            // Capture any new request that arrives; overwrite address/data so
            // we always hold the most-recent request (MEMACCESS sends only one
            // at a time per arbitration round, so no silent drop occurs).
            if (core_read_i || core_read_block_i || core_read_vector_i || core_write_i) begin
                pend_addr_q  <= core_addr_i;
                pend_wdata_q <= core_wdata_i;
                pend_be_q    <= core_be_i;
                pend_vl_q    <= core_vl_i;
            end
            if (core_read_i)        pend_read_q   <= 1'b1;
            if (core_read_block_i)  pend_block_q  <= 1'b1;
            if (core_read_vector_i) pend_vector_q <= 1'b1;
            if (core_write_i)       pend_write_q  <= 1'b1;

            unique case (state)
            IDLE: begin
                m_mem_req <= 1'b0;
                // Drain pending requests (read types take priority over writes;
                // block/vector before scalar word reads).
                if (pend_read_q || pend_block_q || pend_vector_q) begin
                    base_q   <= pend_addr_q; addr_q <= pend_addr_q; cnt_q <= 0;
                    total_q  <= pend_block_q  ? BLOCK_WORDS[5:0] :
                                pend_vector_q ? {1'b0, pend_vl_q} : 6'd1;
                    m_mem_addr <= pend_addr_q; m_mem_we <= 1'b0; m_mem_req <= 1'b1;
                    pend_read_q <= 1'b0; pend_block_q <= 1'b0; pend_vector_q <= 1'b0;
                    state <= RD_REQ;
                end else if (pend_write_q) begin
                    m_mem_addr  <= pend_addr_q; m_mem_wdata <= pend_wdata_q;
                    m_mem_be    <= pend_be_q;   m_mem_we    <= 1'b1; m_mem_req <= 1'b1;
                    pend_write_q <= 1'b0;
                    state <= WR_REQ;
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
            WR_REQ: if (m_mem_gnt) begin
                // Acknowledge writes on a DEDICATED wire (core_wack_o), never on
                // core_valid_o: a write ack carries stale core_rdata_o, and if it
                // shared core_valid_o it would be miscounted as a data word by a
                // concurrently-armed block-read receiver in MEMACCESS (corrupting
                // the filled cache line). Keeping the two channels separate lets the
                // single-outstanding bridge interleave a write ack and a read word
                // unambiguously.
                m_mem_req <= 1'b0; m_mem_we <= 1'b0; core_wack_o <= 1'b1; state <= IDLE;
            end
            default: state <= IDLE;
            endcase
        end
    end
endmodule
