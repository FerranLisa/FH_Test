// One-shot mailbox. Software arms both S2MM transfers before toggling arm.
// cfg fields are held until completion or reset. xpm_cdc_handshake transfers
// the complete trigger/configuration packet atomically into each RX clock.
module fh_monitor_input (
    (* X_INTERFACE_PARAMETER="ASSOCIATED_BUSIF M_AXIS, ASSOCIATED_RESET resetn, FREQ_HZ 120000000" *)
    input wire ctrl_clk,
    (* X_INTERFACE_PARAMETER="POLARITY ACTIVE_LOW" *) input wire resetn,
    input wire rx_clk, fval, lval,
    input wire [191:0] pixels,
    input wire full_trigger, input wire [31:0] frame_id,
    input wire [31:0] cfg_xy, cfg_mode,
    output wire [31:0] status, output reg [31:0] captured_id,
    (* X_INTERFACE_INFO="xilinx.com:interface:axis:1.0 M_AXIS TDATA" *)
    output wire [127:0] m_axis_tdata,
    (* X_INTERFACE_INFO="xilinx.com:interface:axis:1.0 M_AXIS TVALID" *)
    output wire m_axis_tvalid,
    (* X_INTERFACE_INFO="xilinx.com:interface:axis:1.0 M_AXIS TREADY" *)
    input wire m_axis_tready,
    (* X_INTERFACE_INFO="xilinx.com:interface:axis:1.0 M_AXIS TLAST" *)
    output wire m_axis_tlast
);
    // mode: bit 0 arm toggle, bit 1 channel reset, bit 2 large view,
    // bits 4:3 log2(step). xy packs unsigned origin x in low half, y high.
    wire local_reset = !resetn || cfg_mode[1];
    wire rx_reset;
    xpm_cdc_async_rst #(.DEST_SYNC_FF(4),.RST_ACTIVE_HIGH(1))
        reset_cross (.src_arst(local_reset),.dest_clk(rx_clk),.dest_arst(rx_reset));
    reg accepted, sending, waiting;
    reg [34:0] command;
    wire received, new_command;
    wire [34:0] rx_command;
    reg completed, failed;
    wire complete_ctrl, fail_ctrl;
    xpm_cdc_single #(.SRC_INPUT_REG(0)) done_cross
        (.src_clk(rx_clk),.src_in(completed),.dest_clk(ctrl_clk),.dest_out(complete_ctrl));
    xpm_cdc_single #(.SRC_INPUT_REG(0)) fail_cross
        (.src_clk(rx_clk),.src_in(failed),.dest_clk(ctrl_clk),.dest_out(fail_ctrl));
    assign status = {28'b0,fail_ctrl,complete_ctrl,waiting,accepted};
    always @(posedge ctrl_clk) begin
        if (local_reset) begin
            accepted<=0; sending<=0; waiting<=0; captured_id<=0; command<=0;
        end else begin
            if (sending && received) sending<=0;
            if (waiting && complete_ctrl==accepted) waiting<=0;
            if (full_trigger && !waiting && !sending && !received && cfg_mode[0]!=accepted) begin
                accepted<=cfg_mode[0]; waiting<=1; sending<=1;
                captured_id<=frame_id;
                command<={cfg_mode[4:2],cfg_xy};
            end
        end
    end
    xpm_cdc_handshake #(.WIDTH(35),.DEST_EXT_HSK(0)) transfer
        (.src_clk(ctrl_clk),.src_in(command),.src_send(sending),.src_rcv(received),
         .dest_clk(rx_clk),.dest_out(rx_command),.dest_req(new_command),.dest_ack(1'b0));
    reg armed;
    reg [34:0] setting;
    wire [15:0] width = setting[32] ? 16'd2048 : 16'd1024;
    wire [15:0] height = setting[32] ? 16'd1536 : 16'd768;
    wire [15:0] x=setting[15:0], y=setting[31:16];
    wire [2:0] step={1'b0,setting[34:33]};
    wire valid, last, done, error;
    wire [127:0] luma;
    fh_monitor_eye eye (.clk(rx_clk),.resetn(!rx_reset),.fval(fval),.lval(lval),
        .sensor_pixels(pixels),.cfg_full(armed),.cfg_x0(x),.cfg_y0(y),
        .cfg_x1(x+(width<<step)),.cfg_y1(y+(height<<step)),.cfg_step_log2(step),
        .luma(luma),.valid(valid),.sof(),.eol(),.eof(last),.frame_done(done),.frame_error(error));
    wire full, empty, wr_busy, rd_busy;
    reg lost;
    always @(posedge rx_clk) begin
        if (rx_reset) begin
            armed<=0; completed<=0; failed<=0; lost<=0; setting<=0;
        end else begin
            if (new_command) begin armed<=1; setting<=rx_command; lost<=fval; end
            if ((valid && (full || wr_busy)) || (armed && lval && !fval)) lost<=1;
            if (armed && done) begin
                armed<=0; completed<=~completed;
                failed<=error || lost || (valid && (full || wr_busy));
            end
        end
    end
    xpm_fifo_async #(.FIFO_MEMORY_TYPE("block"),.FIFO_WRITE_DEPTH(2048),
        .WRITE_DATA_WIDTH(129),.READ_DATA_WIDTH(129),.READ_MODE("fwft"),
        .FIFO_READ_LATENCY(0),.USE_ADV_FEATURES("0000")) queue (
        .rst(rx_reset),.wr_clk(rx_clk),.wr_en(valid && !full && !wr_busy),
        .din({last,luma}),.full(full),.wr_rst_busy(wr_busy),
        .rd_clk(ctrl_clk),.rd_en(m_axis_tvalid && m_axis_tready),
        .dout({m_axis_tlast,m_axis_tdata}),.empty(empty),.rd_rst_busy(rd_busy),
        .sleep(1'b0),.injectsbiterr(1'b0),.injectdbiterr(1'b0));
    assign m_axis_tvalid=!empty && !rd_busy;
endmodule
