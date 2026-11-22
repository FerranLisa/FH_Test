// One eye of the live monitor, in its GMAX receiver clock domain.
// The acquisition controller supplies cfg_full only for monitor-eligible
// FULL triggers and holds the configuration stable at the rising edge of fval.
// Output is a packed raster of 8-bit luminance. Each supported monitor width
// is a multiple of 16, so all emitted beats contain exactly 16 valid bytes.
// A downstream FIFO must absorb the sensor burst. It cannot stall this input.
// Commit the destination buffer only after frame_done with frame_error clear.
module fh_monitor_eye (
    input wire clk, resetn, fval, lval,
    input wire [191:0] sensor_pixels,
    input wire cfg_full,
    input wire [15:0] cfg_x0, cfg_y0, cfg_x1, cfg_y1,
    input wire [2:0] cfg_step_log2,
    output reg [127:0] luma,
    output reg valid, sof, eol, eof,
    output wire frame_done,
    output wire frame_error
);
    wire [191:0] selected;
    wire [15:0] keep;
    wire first_group, last_line_group, last_frame_group, geometry_error;
    fh_router_live router (
        .clk(clk), .resetn(resetn), .fval(fval), .lval(lval), .pixels(sensor_pixels),
        .cfg_enable(cfg_full), .cfg_x0(cfg_x0), .cfg_y0(cfg_y0),
        .cfg_x1(cfg_x1), .cfg_y1(cfg_y1), .cfg_step_log2(cfg_step_log2),
        .out_pixels(selected), .out_keep(keep), .out_sof(first_group),
        .out_eol(last_line_group), .out_eof(last_frame_group),
        .frame_done(frame_done), .frame_error(geometry_error)
    );

    // Prefix counts form a balanced tree, including for an unaligned ROI.
    wire [4:0] prefix [0:4][0:15];
    genvar lane, level;
    generate
        for (lane=0; lane<16; lane=lane+1) begin : count_lane
            assign prefix[0][lane] = {4'b0,keep[lane]};
            for (level=0; level<4; level=level+1) begin : count_stage
                if (lane >= (1<<level))
                    assign prefix[level+1][lane] = prefix[level][lane] +
                                                    prefix[level][lane-(1<<level)];
                else
                    assign prefix[level+1][lane] = prefix[level][lane];
            end
        end
    endgenerate
    reg [127:0] pending;
    reg [3:0] count;
    reg pending_sof, packing_error;
    wire [3:0] used = first_group ? 4'd0 : count;
    wire [5:0] total = used + {1'b0,prefix[4][15]};
    reg [255:0] combined;
    integer n;
    always @* begin
        combined = {128'b0,pending};
        for (n=0; n<16; n=n+1)
            if (keep[n])
                combined[(used + prefix[4][n] - 1)*8 +: 8] = selected[n*12+2 +: 8];
    end

    assign frame_error = geometry_error || packing_error;
    always @(posedge clk) begin
        valid <= 0; sof <= 0; eol <= 0; eof <= 0;
        if (!resetn) begin
            count <= 0; pending <= 0; pending_sof <= 0; packing_error <= 0;
        end else if (|keep) begin
            if (first_group) packing_error <= 0;
            if (last_line_group && total != 16) packing_error <= 1;
            if (total >= 16) begin
                luma <= combined[127:0];
                valid <= 1;
                sof <= first_group || pending_sof;
                eol <= last_line_group;
                eof <= last_frame_group;
                pending <= combined[255:128];
                pending_sof <= 0;
            end else begin
                pending <= combined[127:0];
                pending_sof <= first_group || pending_sof;
            end
            count <= total[3:0];
        end else if (frame_done) begin
            count <= 0; pending_sof <= 0; packing_error <= 0;
        end
    end
endmodule
