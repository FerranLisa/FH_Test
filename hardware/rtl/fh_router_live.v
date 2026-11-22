// Live selector in the receiver pixel clock domain. Lane 0 is the leftmost
// pixel. WIDTH must be a multiple of LANES. fval encloses one frame; lval
// is high for consecutive groups of a line, with a low interval between lines.
// Configuration is synchronous to clk and sampled on the rising edge of fval.
// Bounds are end-exclusive. Point decimation is anchored at (x0,y0).
// Each output beat preserves lane positions: consume lanes selected by keep,
// in ascending order. No backpressure can be applied to the receiver.
module fh_router_live #(
    parameter integer WIDTH = 4096, HEIGHT = 3072, LANES = 16, BITS = 12
)(
    input wire clk, resetn,
    input wire fval, lval,
    input wire [LANES*BITS-1:0] pixels,
    input wire cfg_enable,
    input wire [15:0] cfg_x0, cfg_y0, cfg_x1, cfg_y1,
    input wire [2:0] cfg_step_log2, // 0..4 => step 1,2,4,8,16
    output reg [LANES*BITS-1:0] out_pixels,
    output reg [LANES-1:0] out_keep,
    output reg out_sof, out_eol, out_eof, // aligned with nonzero out_keep
    output reg frame_done, frame_error // completion/status at input EOF
);
    reg prev_frame, prev_line, enabled, selected_frame, bad;
    reg [15:0] x, y, x0, y0, x1, y1, mask;
    wire start = fval && !prev_frame;
    wire config_ok = cfg_step_log2 <= 4 && cfg_x0 < cfg_x1 &&
                     cfg_x1 <= WIDTH && cfg_y0 < cfg_y1 && cfg_y1 <= HEIGHT;
    // The first group may coincide with the rising edge of fval.
    wire active = start ? cfg_enable && config_ok : enabled;
    wire [15:0] left = start ? cfg_x0 : x0, right = start ? cfg_x1 : x1;
    wire [15:0] top = start ? cfg_y0 : y0, bottom = start ? cfg_y1 : y1;
    wire [15:0] stride_mask = start ? ((16'd1 << cfg_step_log2)-1'b1) : mask;
    wire [15:0] base_x = start ? 16'd0 : x, row = start ? 16'd0 : y;
    wire [15:0] last_x = left + ((right-left-1'b1) & ~stride_mask);
    wire [15:0] last_y = top + ((bottom-top-1'b1) & ~stride_mask);
    wire emit_row = active && fval && lval && row >= top && row < bottom &&
                    (((row-top) & stride_mask) == 0);
    wire [LANES-1:0] keep;
    genvar i;
    generate for (i=0; i<LANES; i=i+1) begin : select_lane
        wire [15:0] col = base_x+i;
        assign keep[i] = emit_row && col >= left && col < right &&
                         (((col-left) & stride_mask) == 0);
    end endgenerate

    always @(posedge clk) begin
        if (!resetn) begin
            prev_frame <= 0; prev_line <= 0; enabled <= 0; selected_frame <= 0;
            x <= 0; y <= 0; bad <= 0; frame_error <= 0; frame_done <= 0;
            out_keep <= 0; out_sof <= 0; out_eol <= 0; out_eof <= 0;
        end else begin
            prev_frame <= fval;
            prev_line <= fval && lval;
            out_keep <= keep;
            out_pixels <= pixels;
            out_sof <= |keep && row == top && left >= base_x && left < base_x+LANES;
            out_eol <= |keep && last_x >= base_x && last_x < base_x+LANES;
            out_eof <= |keep && row == last_y && last_x >= base_x && last_x < base_x+LANES;
            frame_done <= prev_frame && !fval && selected_frame;
            if (start) begin
                selected_frame <= cfg_enable;
                enabled <= cfg_enable && config_ok;
                bad <= !config_ok;
                frame_error <= 0;
                x0 <= cfg_x0; x1 <= cfg_x1; y0 <= cfg_y0; y1 <= cfg_y1;
                mask <= stride_mask;
                x <= 0; y <= 0;
            end
            if (fval && lval) begin
                x <= base_x + LANES;
                if (base_x >= WIDTH || row >= HEIGHT) bad <= 1;
            end else if (prev_line) begin
                x <= 0; y <= y+1'b1;
                if (x != WIDTH) bad <= 1;
            end
            if (prev_frame && !fval) begin
                enabled <= 0;
                frame_error <= selected_frame && (bad || (prev_line && x != WIDTH) ||
                                                   y + prev_line != HEIGHT);
            end
        end
    end
endmodule
