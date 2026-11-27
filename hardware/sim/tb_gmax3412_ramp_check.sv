`timescale 1ns/1ps
module tb_gmax3412_ramp_check;
    reg clk=0, reset=1, arm=0;
    reg [191:0] raw_data=0, previous_beat=0, older_beat=0;
    reg [15:0] late_lanes=0, very_late_lanes=0;
    wire [191:0] data;
    wire alignment_error;
    gmax3412_word_align aligner(.clk(clk), .reset(reset), .raw_data(raw_data),
                                .data(data), .error(alignment_error));
    wire [3:0] state;
    wire fval,lval;
    wire roi_fval,roi_lval;
    integer roi_beats=0,roi_errors=0;
    gmax3412_full_frame_sync #(.GROUPS(2),.ROWS(6),.ROI_ROWS(2)) roi_decoder(
        .clk(clk),.reset(reset),.alignment_error(alignment_error),.data(data),
        .frame_valid(roi_fval),.line_valid(roi_lval));
    integer groups_seen=0, lines_seen=0, frames_seen=0, malformed=0;
    integer group_in_test, lane_index, expected_pixel;
    reg check_dma_data=0;
    reg previous_line=0, previous_frame=0;
    gmax3412_full_frame_sync #(.GROUPS(2),.ROWS(2)) decoder(
        .clk(clk),.reset(reset),.alignment_error(alignment_error),.data(data),.frame_valid(fval),.line_valid(lval));
    always @(posedge clk) begin
        if (roi_lval && roi_fval) roi_beats=roi_beats+1;
        if (roi_lval && !roi_fval) roi_errors=roi_errors+1;
        if (fval && lval) begin
            groups_seen=groups_seen+1;
            if (check_dma_data) begin
                for (lane_index=0; lane_index<16; lane_index=lane_index+1) begin
                    expected_pixel=(1010 + group_in_test/2 + 16*(group_in_test%2) + lane_index)%1024;
                    if (expected_pixel==0) expected_pixel=1;
                    if (data[12*lane_index+:12] !== expected_pixel[11:0])
                        $fatal(1,"DMA group %0d lane %0d failed",group_in_test,lane_index);
                end
                group_in_test=group_in_test+1;
            end
        end
        if (previous_line && !lval) lines_seen=lines_seen+1;
        if (previous_frame && !fval) frames_seen=frames_seen+1;
        if (!fval && lval) malformed=malformed+1;
        previous_frame=fval;
        previous_line=lval;
    end
    always #5 clk=~clk;
    gmax3412_ramp_check #(.GROUPS(2), .ROWS(2)) dut(
        .clk(clk),.reset(reset),.arm(arm),.alignment_error(alignment_error),.data(data),.state(state));
    task send(input [191:0] beat);
        integer lane;
        begin
            @(negedge clk);
            for (lane=0; lane<16; lane=lane+1)
                raw_data[12*lane+:12] = very_late_lanes[lane] ? older_beat[12*lane+:12] :
                    late_lanes[lane] ? previous_beat[12*lane+:12] : beat[12*lane+:12];
            older_beat=previous_beat;
            previous_beat=beat;
            @(posedge clk); #1;
        end
    endtask
    task marker(input [9:0] tag);
        begin
            send({16{12'h3ff}}); send(0); send(0); send({16{2'b0,tag}});
        end
    endtask
    task run_frame(input integer fault, input integer wanted);
        integer y,g,l,v;
        reg [191:0] beat;
        begin
            check_dma_data=(wanted==8);
            group_in_test=0;
            arm=0; send({16{12'h165}}); arm=1; send({16{12'h165}});
            for(y=0;y<2;y=y+1) begin
                marker(y==0 ? 10'h200 : 10'h2ac);
                for(g=0;g<2;g=g+1) begin
                    for(l=0;l<16;l=l+1) begin
                        v=(1010+y+16*g+l)%1024;
                        beat[12*l+:12]=(v==0 ? 1 : v);
                    end
                    if(fault==1 && y==1 && g==1) beat[180]=~beat[180];
                    send(beat);
                end
                marker((fault==2 || y==1) ? 10'h274 : 10'h0d8);
            end
            repeat (8) send({16{12'h165}});
            if (check_dma_data && group_in_test!=4) $fatal(1,"DMA group count incorrect");
            if(state!==wanted[3:0]) $fatal(1,"fault %d state %h expected %d",fault,state,wanted);
            arm=0;
            send(0);
            if(fault==1 && {dut.snapshot_stage,dut.snapshot_row,dut.snapshot_group,
                            dut.snapshot_base,dut.snapshot_words[150+:10]} !==
                           {4'd2,12'd1,9'd1,10'd3,10'd19})
                $fatal(1,"Pixel failure snapshot incorrect");
            if(fault==2 && {dut.snapshot_stage,dut.snapshot_row,dut.snapshot_group,
                            dut.snapshot_words} !== {4'd6,12'd0,9'd2,{16{10'h274}}})
                $fatal(1,"Early EOF snapshot incorrect");
        end
    endtask
    initial begin
        send(0); reset=0;
        run_frame(0,8);
        if (roi_beats!=4 || roi_errors!=0 || roi_fval)
            $fatal(1,"Native ROI EOF or pixel count incorrect");
        if (groups_seen!=4 || lines_seen!=2 || frames_seen!=1 || malformed!=0)
            $fatal(1,"DMA qualifiers did not identify the full image");
        late_lanes=16'h3051; // D0, D4, D6, D12 and D13 from the ILA capture
        run_frame(0,8);
        late_lanes=~late_lanes;
        run_frame(0,8);
        very_late_lanes=1;
        run_frame(0,11);
        if (groups_seen!=12 || frames_seen!=3 || malformed==0)
            $fatal(1,"Rejected SOF reached DMA or a valid frame was lost");
        malformed=0;
        very_late_lanes=0;
        run_frame(0,8);
        run_frame(1,10); run_frame(2,9);
        if (malformed!=1) $fatal(1,"Premature EOF not flagged for DMA");
        $display("PASS"); $finish;
    end
endmodule
