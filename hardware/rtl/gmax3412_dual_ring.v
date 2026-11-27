`timescale 1ns/1ps
// Rolling PL DDR4 capture. GPIO command/status interface; AXI-Lite control master.
// Storage is fixed to reserved DDR apertures; software cannot supply DMA addresses.
module gmax3412_dual_ring #(parameter RESET_WAIT=128, POLL_LIMIT=240000000, TICKS_PER_US=120,
 IMAGE_WIDTH=4096,IMAGE_HEIGHT=3072,ROI_HEIGHT=1024, BUFFER_BYTES=32'h80000000)(
 (* X_INTERFACE_PARAMETER="ASSOCIATED_BUSIF M_AXI, ASSOCIATED_RESET resetn, FREQ_HZ 120000000" *) input wire clk,
 (* X_INTERFACE_PARAMETER="POLARITY ACTIVE_LOW" *) input wire resetn,
 input wire calib_ready, rtc_seconds_irq,
 input wire [1:0] texp_pins,
 input wire fval_a, fval_b, lval_a, lval_b, rx_clk_a, rx_clk_b,
 output wire trigger_pair, output reg readout_pair,
 output reg [3:0] texp_drive,
 output wire [3:0] window_spi,
 output reg monitor_full_trigger, output wire [31:0] monitor_frame_id,
 input wire [31:0] control, output reg [31:0] status,
 output reg [31:0] m_axi_awaddr, output wire [2:0] m_axi_awprot,
 output reg m_axi_awvalid, input wire m_axi_awready,
 output reg [31:0] m_axi_wdata, output wire [3:0] m_axi_wstrb,
 output reg m_axi_wvalid, input wire m_axi_wready,
 input wire [1:0] m_axi_bresp,input wire m_axi_bvalid,output wire m_axi_bready,
 output reg [31:0] m_axi_araddr,output wire [2:0] m_axi_arprot,
 output reg m_axi_arvalid,input wire m_axi_arready,
 input wire [31:0] m_axi_rdata,input wire [1:0] m_axi_rresp,
 input wire m_axi_rvalid,output wire m_axi_rready
);
 // Two logical 2 GiB apertures on the existing shared DDR controller.
 // Chips form one wide memory interface; these are address partitions, not chip selects.
 reg [31:0] write_offset,reserved_offset,next_frame_id,reserved_id;
 reg id_exhausted;
 reg [7:0] lut_write,scan_index;
 reg [255:0] lut_valid;
 reg [31:0] frame_ids[0:255],frame_offsets[0:255],frame_lengths[0:255];
 reg [9:0] frame_seeds[0:255];
 reg frame_rois[0:255];
 reg lookup_mode;
 reg [31:0] query_id,query_offset,query_length,query_tick,reserved_tick;
 reg [31:0] frame_ticks[0:255];
 reg [9:0] query_seed;
 reg query_valid,query_roi;
 wire [31:0] frame_bytes;
 wire [31:0] allocation=frame_bytes+128;
 wire [31:0] candidate=({1'b0,write_offset}+allocation>BUFFER_BYTES)?0:write_offset;

 
 // Bits 0/1 drive TEXP1 A/B; bits 2/3 drive TEXP2 A/B.
 assign trigger_pair=|texp_drive;
 reg [19:0] exposure_us=1000;
 reg [31:0] exposure_left;
 reg sensor, roi;
 reg [31:0] full_count, roi_count, ratio, sequence_slot;
 reg [63:0] usec, slot_ticks, next_trigger;
 reg [6:0] sub_us;
 reg epoch;
 localparam SLOT_CYCLES=4000*TICKS_PER_US;
 reg [31:0] trigger_slots;
 reg [31:0] head_a,source_a,source_b;
 wire [31:0] cap_base=sensor ? 32'hA0090000 : 32'hA0040000;
 wire [31:0] dma_base=sensor ? 32'hA00A0000 : 32'hA0050000;
 wire [63:0] frame_address=64'h1000000040 + (sensor ? 64'h80000000 : 0) + reserved_offset;
 assign frame_bytes=IMAGE_WIDTH*(roi ? ROI_HEIGHT : IMAGE_HEIGHT)*2;
 wire [31:0] frame_seed=(7 + (sensor ? 113 : 0) + (roi ? 503 : 0) +
                           37*(roi ? roi_count : full_count)) & 1023;
 reg toggle, running, done, stopped, stop_request;
 reg [7:0] state;
 // Broadcast the two changing window bytes between frames. The low bytes
 // retain the initialized physical row origin and the 256-row alignment.
 reg exposure_pending;
 reg window_known, window_roi, target_roi, second_word, select_n, sck;
 reg [23:0] shift_word;
 reg [4:0] bit_index;
 reg [2:0] spi_state;
 reg [15:0] spi_delay;
 reg late_window, pending_roi, armed_switch, roi_budget_known, roi_budget_ok;
 reg [1:0] spi_word;
 reg grouped;
 (* ASYNC_REG="TRUE" *) reg [1:0] fv_meta, fv_sync;
 wire recovery_window_safe;
 wire service_window=running && (state==5 || (state==95 && recovery_window_safe));
 wire want_roi=state==5 && (!stop_request || exposure_pending) && sequence_slot!=0;
 wire write_window=service_window && (!window_known || want_roi!=window_roi) &&
                   (!late_window || state==95 || (trigger_pair && fv_sync==0));
 assign window_spi={running,select_n,sck,shift_word[23]};
 always @(posedge clk) begin
   if(!resetn) begin
     window_known<=0;window_roi<=0;target_roi<=0;second_word<=0;select_n<=1;sck<=1;
     spi_state<=0;spi_delay<=0;shift_word<=0;bit_index<=0;spi_word<=0;grouped<=0;
   end else if(spi_delay!=0) spi_delay<=spi_delay-1'b1;
   else begin
     if(!running) window_known<=0;
     if(spi_state!=0 || write_window)
       spi_delay<=TICKS_PER_US-1;
     case(spi_state)
       0:if(write_window) begin
         target_roi<=want_roi;second_word<=0;
         grouped<=late_window && state==5;
         spi_word<=0;
         shift_word<=late_window && state==5 ? 24'h000101 :
                     {16'h001e,want_roi ? 8'h04 : 8'h00};spi_state<=1;
       end
       1:begin select_n<=0;bit_index<=23;spi_state<=2;end
       2:begin sck<=0;spi_state<=3;end
       3:begin sck<=1;spi_state<=4;end
       4:if(bit_index==0) begin select_n<=1;spi_state<=5;end
         else begin sck<=0;shift_word<=shift_word<<1;bit_index<=bit_index-1'b1;spi_state<=3;end
       5:if(grouped && spi_word!=3) begin
           case(spi_word)
             0:shift_word<={16'h001e,target_roi ? 8'h04 : 8'h00};
             1:shift_word<={16'h0020,target_roi ? 8'h04 : 8'h0c};
             2:shift_word<=24'h000100;
           endcase
           second_word<=spi_word==2;
           spi_word<=spi_word+1'b1;spi_state<=1;
         end else if(!second_word) begin
           shift_word<={16'h0020,target_roi ? 8'h04 : 8'h0c};
           second_word<=1;spi_state<=1;
         end else begin window_known<=1;window_roi<=target_roi;spi_state<=0;end
     endcase
   end
 end
 // A trigger may precede arming its receiver while the previous DMA drains.
 // One outstanding reservation is sufficient: the new readout must be armed
 // before its SOF. Each receiver acknowledges arm independently.
 reg readout_overrun, missed_arm, skip_after_full, issued_last_id;
 reg [31:0] exposure_slot, issue_id, issued_monitor_id, pending_tick;
 reg [1:0] pending_edges;
 // FVAL is decoded from several RX state bits. Register it before CDC.
 reg fv_source_a=0, fv_source_b=0;
 always @(posedge rx_clk_a) fv_source_a<=fval_a;
 always @(posedge rx_clk_b) fv_source_b<=fval_b;
 reg [1:0] fv_last, awaiting_sof, rx_armed;
 wire [1:0] sof=fv_sync & ~fv_last;
 always @(posedge clk) begin
   if(!resetn) begin fv_meta<=0;fv_sync<=0;fv_last<=0;end
   else begin fv_meta<={fv_source_b,fv_source_a};fv_sync<=fv_meta;fv_last<=fv_sync;end
 end
 // No new trigger during the exposure-to-readout transition (includes FOT).
 // After both SOFs the next exposure may overlap the current stereo readout.
 wire sensor_phase_ready=awaiting_sof==0 && (epoch || fv_sync==0);
 reg [1:0] bus;
 reg response;
 reg [31:0] readback;
 wire arm_ack=(bus==0 && !response && state==20 && readback[0]);
 wire [1:0] armed_now=rx_armed | (arm_ack ? (sensor ? 2'b10 : 2'b01) : 2'b00);
 reg [31:0] completed;
 (* ASYNC_REG="TRUE" *) reg [1:0] calibrated;
 always @(posedge clk) if(!resetn) calibrated<=0; else calibrated<={calibrated[0],calib_ready};
 reg [31:0] error, timer, cycles, last_dma, last_cap;
 // A missed window can leave a sensor readout in flight after DMA reset.
 // Restore FULL only after both eyes saw that frame start and finish.
 assign recovery_window_safe=error!=14 || (!trigger_pair && awaiting_sof==0 && fv_sync==0);

 // All edge captures use the same sampling pipeline and free-running clock.
 reg [63:0] counter, rtc_edge;
 reg [31:0] rtc_sequence;
 (* ASYNC_REG="TRUE" *) reg [2:0] edge_meta, edge_sync;
 reg [2:0] edge_previous;
 reg [1:0] completed_edges, edges_before_trigger;
 reg [63:0] rise[0:1], fall_time[0:1];
 // Keep each eye's two most recent completed pulses. The next rise can
 // arrive before the previous DMA has published its LUT entry.
 reg [63:0] pulse_start[0:3], pulse_end[0:3];
 reg [3:0] pulse_valid;
 reg [63:0] frame_rise[0:255], frame_fall[0:255], query_rise, query_fall;
 integer channel;
 always @(posedge clk) begin
   if (!resetn) begin
     pulse_valid<=0;completed_edges<=0; counter<=0; rtc_edge<=0; rtc_sequence<=0;
     edge_meta<=0; edge_sync<=0; edge_previous<=0;
     for(channel=0;channel<2;channel=channel+1) begin rise[channel]<=0; fall_time[channel]<=0; end
   end else begin
     counter<=counter+1;
     edge_meta<={rtc_seconds_irq,texp_pins}; edge_sync<=edge_meta; edge_previous<=edge_sync;
     if(edge_sync[2] && !edge_previous[2]) begin rtc_edge<=counter; rtc_sequence<=rtc_sequence+1; end
     for(channel=0;channel<2;channel=channel+1) begin
       if(edge_sync[channel] && !edge_previous[channel]) begin
         rise[channel]<=counter;
         pulse_valid[{channel[0],completed_edges[channel]}]<=0;
       end
       if(!edge_sync[channel] && edge_previous[channel]) begin
         fall_time[channel]<=counter;
         pulse_valid[{channel[0],completed_edges[channel]}]<=1;
         pulse_start[{channel[0],completed_edges[channel]}]<=rise[channel];
         pulse_end[{channel[0],completed_edges[channel]}]<=counter;
         completed_edges[channel]<=~completed_edges[channel];
       end
     end
   end
 end
 wire command=control[31]!=toggle;
 // Preserve the first 256 event cycles of each run, including simultaneous
 // events. Read through GPIO page 3 after stop, without toggling a command.
 reg trace_running, trace_full;
 reg missed_window;
 wire [1:0] trace_fall=edge_previous[1:0] & ~edge_sync[1:0];
 reg [2:0] trace_detail[0:255];
 reg [2:0] detail_read;
 // Sample the first FULL of each run. A toggle preserves narrow RX LVAL
 // edges when crossing to the common timestamp clock.
 wire [1:0] line_clock={rx_clk_b,rx_clk_a}, line_valid={lval_b,lval_a};
 wire [1:0] frame_valid={fval_b,fval_a};
 wire [31:0] first_line[0:1], line_period[0:1], line_count[0:1];
 wire [1:0] roi_overlap_ready;
 wire [31:0] switch_rows[0:1];
 for(genvar eye=0;eye<2;eye=eye+1) begin: line_measure
   reg previous=0, token=0;
   always @(posedge line_clock[eye]) begin
     previous<=line_valid[eye] && frame_valid[eye];
     if(!previous && line_valid[eye] && frame_valid[eye]) token<=~token;
   end
   (* ASYNC_REG="TRUE" *) reg [1:0] sync_line;
   reg last_token, frozen, first_fall_seen;
   reg [31:0] first_stamp,period,rows,fall_stamp;
   assign first_line[eye]=first_stamp-fall_stamp;
   assign line_period[eye]=period;
   assign line_count[eye]=rows;
   // A 1 ms exposure allows 300 remaining rows at 2.5 us per row,
   // five TP rows, four SPI words and the fixed deadline guard.
   reg [12:0] active_rows;
   always @(posedge clk) begin
     if(!resetn || !running || !fv_sync[eye]) active_rows<=0;
     else if(sync_line[1]!=last_token) active_rows<=active_rows+1'b1;
   end
   assign roi_overlap_ready[eye]=fv_sync[eye] && active_rows>=IMAGE_HEIGHT-300 &&
                                 period!=0 && period<=(5*TICKS_PER_US)/2+1;
   reg capture_switch;
   reg [15:0] switch_count;
   assign switch_rows[eye]={16'b0,switch_count};
   always @(posedge clk) begin
     if(!resetn || (running && !trace_running)) begin
       capture_switch<=0;switch_count<=0;
     end else if(running) begin
       // The previous ROI has ended before the new exposure's falling edge.
       if(trace_fall[eye] && armed_switch && switch_count==0) capture_switch<=1;
       if(capture_switch && sync_line[1]!=last_token) switch_count<=switch_count+1'b1;
       if(capture_switch && fv_last[eye] && !fv_sync[eye]) capture_switch<=0;
     end
   end
   always @(posedge clk) begin
     sync_line<={sync_line[0],token};last_token<=sync_line[1];
     if(!resetn || !running) begin
       frozen<=0;
       if(!resetn) begin rows<=0;first_stamp<=0;fall_stamp<=0;period<=0;end
     end else if(!trace_running) begin
       rows<=0;first_stamp<=0;fall_stamp<=0;period<=0;first_fall_seen<=0;
     end else if(!frozen && epoch) begin
       if(trace_fall[eye] && !first_fall_seen) begin
         fall_stamp<=counter[31:0];first_fall_seen<=1;
       end
       if(sync_line[1]!=last_token) begin
         if(rows==0) first_stamp<=counter[31:0];
         if(rows==1) period<=counter[31:0]-first_stamp;
         rows<=rows+1'b1;
       end
       if(fv_last[eye] && !fv_sync[eye]) frozen<=1;
     end
   end
 end
 reg [8:0] trace_count;
 reg [63:0] trace_mem[0:255];
 reg [63:0] trace_read;
 // The measured time from ROI exposure end to stereo DMA publication must
 // leave room for four SPI words, RX arming and timing variation.
 wire trial_full=exposure_slot==0 && window_roi && roi && sequence_slot==ratio &&
                 exposure_us==1000 && roi_budget_known && roi_budget_ok && state<89;
 wire trial_roi=exposure_slot==1 && sequence_slot==0 && !roi && !window_roi &&
                exposure_us==1000 && (&roi_overlap_ready) && state<89;
 wire trial_window=trial_full || trial_roi;
 wire ready_to_issue=!trigger_pair && !exposure_pending && !issued_last_id &&
                     sensor_phase_ready && window_known && spi_state==0 && !write_window &&
                     (window_roi==(exposure_slot!=0) || trial_window);
 wire trace_tick=!stop_request && error==0 && state<89 &&
                 (epoch ? slot_ticks==next_trigger : state==21 && ready_to_issue &&
                  !skip_after_full && !(command && control[30:28]==3));
 wire trace_dma=state==26 && bus==0 && !response;
 wire [1:0] trace_rise=edge_sync[1:0] & ~edge_previous[1:0];
 wire [1:0] trace_eof=fv_last & ~fv_sync;
 wire [8:0] trace_events={spi_state==4 && spi_delay==0 && bit_index==0 && second_word,
                          spi_state==1 && spi_delay==0 && !second_word && (!grouped || spi_word==0),
                          trace_dma && sensor,trace_dma && !sensor,
                          trace_eof,trace_rise,trace_tick};
 wire [7:0] trace_slot=trigger_slots[7:0]+trace_tick;
 always @(posedge clk) begin
   trace_read<=trace_mem[control[15:8]];
   detail_read<=trace_detail[control[15:8]];
   trace_running<=running;
   if(!resetn || (running && !trace_running)) begin
     trace_count<=0;
     trace_full<=0;
   end else if(running && (|trace_events || |trace_fall)) begin
     if(trace_count==256) trace_full<=1;
     else begin
       trace_detail[trace_count[7:0]]<={late_window || (trace_tick && trial_window && ready_to_issue && !skip_after_full),trace_fall};
       trace_mem[trace_count[7:0]]<={counter[31:0],trace_slot,state,spi_state,
                                     fv_sync,window_roi,skip_after_full,trace_events};
       trace_count<=trace_count+1'b1;
     end
   end
 end
 // The monitor observes the same accepted trigger and ID as the rolling buffer.
 assign monitor_frame_id = issued_monitor_id;
 assign m_axi_awprot=0;assign m_axi_arprot=0;assign m_axi_wstrb=15;
 assign m_axi_bready=bus==1;assign m_axi_rready=bus==2;
 task write_reg(input [31:0] a,input [31:0] d);
 begin m_axi_awaddr<=a;m_axi_wdata<=d;m_axi_awvalid<=1;m_axi_wvalid<=1;bus<=1;end
 endtask
 task read_reg(input [31:0] a);
 begin m_axi_araddr<=a;m_axi_arvalid<=1;bus<=2;end
 endtask
 always @* begin
   case(control[3:0])
    0:status=32'h3412D035;
    1:status={16'b0,state,4'b0,stopped,(error!=0),done,running};
    2:status=BUFFER_BYTES;
    3:status=full_count;4:status=error;5:status=roi_count;
    6:status=last_dma;7:status=last_cap;
    8:status=ratio;9:status=4000;
    10:status=usec[31:0];11:status=trigger_slots;
    12:status={31'b0,calibrated[1]};
    13:status=write_offset;
    14:status=frame_address[31:0];15:status={1'b1,trigger_pair,1'b1,27'b0,sensor,roi};
   endcase
   if(lookup_mode) case(control[3:0])
    2:status=query_id;
    3:status=query_offset+32'h40;
    5:status=32'h10; // add 0x80000000 to address for Slave
    6:status=query_length;
    7:status={30'b0,query_roi,query_valid};
    8:status={22'b0,query_seed};
    9:status=(query_seed+113)&1023;
    10:status=query_tick;
    default:begin end
   endcase
   if(control[7:4]==1) case(control[3:0])
     0:status=32'h46545431;
     1:status=rtc_sequence;
     2:status=rtc_edge[31:0]; 3:status=rtc_edge[63:32];
     4:status=counter[31:0]; 5:status=counter[63:32];
     6:status=rise[0][31:0]; 7:status=rise[0][63:32];
     8:status=fall_time[0][31:0]; 9:status=fall_time[0][63:32];
     10:status=rise[1][31:0]; 11:status=rise[1][63:32];
     12:status=fall_time[1][31:0]; 13:status=fall_time[1][63:32];
     default:status=0;
   endcase
   if(control[7:4]==2) case(control[3:0])
     0:status=query_rise[31:0]; 1:status=query_rise[63:32];
     2:status=query_fall[31:0]; 3:status=query_fall[63:32];
     default:status=0;
   endcase
   if(control[7:4]==3) case(control[3:0])
     0:status=32'h54524331;
     1:status={22'b0,trace_full,trace_count};
     2:status=trace_read[63:32];
     3:status=trace_read[31:0];
     4:status=TICKS_PER_US;
     5:status=32'h54524332;
     6:status={29'b0,detail_read};
     default:status=0;
   endcase
   if(control[7:4]==4) case(control[3:0])
     0:status=first_line[0];1:status=line_period[0];2:status=line_count[0];
     3:status=first_line[1];4:status=line_period[1];5:status=line_count[1];
     6:status=switch_rows[0];7:status=switch_rows[1];
     default:status=0;
   endcase
 end
 always @(posedge clk) begin
   monitor_full_trigger<=0;
  if(!resetn) begin
   late_window<=0;pending_roi<=0;armed_switch<=0;missed_window<=0;roi_budget_known<=0;roi_budget_ok<=1;
   awaiting_sof<=0;rx_armed<=0;readout_overrun<=0;exposure_pending<=0;missed_arm<=0;skip_after_full<=0;issued_last_id<=0;
   exposure_slot<=0;issue_id<=0;issued_monitor_id<=0;pending_tick<=0;pending_edges<=0;
   write_offset<=0;reserved_offset<=0;next_frame_id<=0;reserved_id<=0;id_exhausted<=0;
   lut_write<=0;scan_index<=0;lut_valid<=0;lookup_mode<=0;
   query_tick<=0;reserved_tick<=0;query_id<=0;query_offset<=0;query_length<=0;query_seed<=0;query_valid<=0;query_roi<=0;
   texp_drive<=0;exposure_left<=0;readout_pair<=0;head_a<=0;source_a<=0;source_b<=0;sensor<=0;roi<=0;
   full_count<=0;roi_count<=0;ratio<=24;sequence_slot<=0;
   usec<=0;slot_ticks<=0;next_trigger<=0;epoch<=0;sub_us<=0;trigger_slots<=0;
   toggle<=0;running<=0;done<=0;stopped<=0;stop_request<=0;
   completed<=0;state<=0;error<=0;timer<=0;cycles<=0;
   last_dma<=0;last_cap<=0;bus<=0;response<=0;readback<=0;
   m_axi_awvalid<=0;m_axi_wvalid<=0;m_axi_arvalid<=0;
   m_axi_awaddr<=0;m_axi_wdata<=0;m_axi_araddr<=0;
  end else begin
   response<=0;readout_pair<=0;
   if(exposure_left!=0) exposure_left<=exposure_left-1;
   else texp_drive<=0;
   if(m_axi_awvalid && m_axi_awready) m_axi_awvalid<=0;
   if(m_axi_wvalid && m_axi_wready) m_axi_wvalid<=0;
   if(m_axi_arvalid && m_axi_arready) m_axi_arvalid<=0;
   if(bus==1 && m_axi_bvalid) begin
    bus<=0;response<=1;
    if(m_axi_bresp!=0) begin error<=2;state<=89;end
   end
   if(bus==2 && m_axi_rvalid) begin
    bus<=0;response<=1;readback<=m_axi_rdata;
    if(m_axi_rresp!=0) begin error<=2;state<=89;end
   end
   if(command) begin
    toggle<=control[31];
    if(control[30:28]!=6) lookup_mode<=0;
    case(control[30:28])
     // One-shot command latches the output mask; zero retains legacy stereo.
     0:if(!running && !trigger_pair && calibrated[1] && control[27:8]!=0) begin
       texp_drive<=control[7:4]==0 ? 4'b0011 : control[7:4];
       exposure_left<=control[27:8]*TICKS_PER_US-1;
     end
     6:begin
       query_rise<=frame_rise[control[15:8]];
       query_fall<=frame_fall[control[15:8]];
       query_tick<=frame_ticks[control[15:8]];
       lookup_mode<=1;query_id<=frame_ids[control[15:8]];
       query_offset<=frame_offsets[control[15:8]];query_length<=frame_lengths[control[15:8]];
       query_seed<=frame_seeds[control[15:8]];query_roi<=frame_rois[control[15:8]];
       query_valid<=lut_valid[control[15:8]];
     end
     7:lookup_mode<=0;
     1:if(!running) begin
      if(control[27:8]<=24) begin ratio<=control[27:8];error<=0;end else error<=1;
     end
     4:if(!running && control[27:8]!=0) exposure_us<=control[27:8];
     5:if(!running) error<=1; // Separate full/ROI capacities removed.
     2:if(!running && !trigger_pair && error==0 && calibrated[1] && !id_exhausted) begin
        begin
         awaiting_sof<=0;rx_armed<=0;readout_overrun<=0;exposure_pending<=0;missed_arm<=0;skip_after_full<=0;issued_last_id<=0;
         late_window<=0;pending_roi<=0;armed_switch<=0;missed_window<=0;roi_budget_known<=0;roi_budget_ok<=1;
         exposure_slot<=0;issue_id<=next_frame_id;
         write_offset<=0;lut_write<=0;lut_valid<=0;running<=1;done<=0;stopped<=0;stop_request<=0;completed<=0;
         full_count<=0;roi_count<=0;sensor<=0;roi<=0;
         usec<=0;sub_us<=0;slot_ticks<=0;next_trigger<=0;epoch<=0;sequence_slot<=0;
         trigger_slots<=0;cycles<=0;timer<=0;state<=1;
        end
       end
     3:if(running) stop_request<=1;
     default:begin end
    endcase
   end
   if(running) begin
    if(late_window && exposure_left<=10*TICKS_PER_US && trigger_pair && (window_roi!=pending_roi || spi_state!=0))
      missed_window<=1;
    if(late_window && window_roi==pending_roi && spi_state==0) late_window<=0;
    cycles<=cycles+1;
    if(epoch) begin
     slot_ticks<=slot_ticks+1;
     if(slot_ticks==next_trigger && !stop_request && error==0 && state<89) begin
      trigger_slots<=trigger_slots+1;next_trigger<=next_trigger+SLOT_CYCLES;
     end
    end
    awaiting_sof<=awaiting_sof & ~sof;
    rx_armed<=armed_now & ~sof;
    if(state<89 && |(sof & (~armed_now | ~awaiting_sof))) missed_arm<=1;
    // A falling TEXP while the preceding image is still being read can
    // stretch optical exposure. Never publish that pair as fixed exposure.
    if(state<89 && |(edge_previous[1:0] & ~edge_sync[1:0] & fv_sync & awaiting_sof))
      readout_overrun<=1;
    // Establish the epoch with both channels armed, then let the slot
    // generator own TEXP independently of all AXI transactions.
    if(!stop_request && !(command && control[30:28]==3) && error==0 && state<89 &&
       ((!epoch && state==21) || (epoch && slot_ticks==next_trigger))) begin
      if(skip_after_full) skip_after_full<=0;
      // Only a qualified format transition may defer the window
      // writes until after TEXP rises. Its falling edge stays fixed.
      else if(ready_to_issue) begin
        late_window<=trial_window; pending_roi<=trial_roi;
        armed_switch<=trial_full;
        if(!epoch) begin epoch<=1;slot_ticks<=1;next_trigger<=SLOT_CYCLES;trigger_slots<=1;end
        awaiting_sof<=2'b11;exposure_pending<=1;pending_tick<=trigger_slots+1;pending_edges<=completed_edges;
        issued_monitor_id<=issue_id;issued_last_id<=(&issue_id);issue_id<=issue_id+1;
        monitor_full_trigger<=exposure_slot==0;skip_after_full<=exposure_slot==0;
        exposure_slot<=exposure_slot==ratio ? 0 : exposure_slot+1;
        texp_drive<=4'b0011;exposure_left<=exposure_us*TICKS_PER_US-1;
      end
    end
    if(sub_us==TICKS_PER_US-1) begin sub_us<=0;usec<=usec+1;end else sub_us<=sub_us+1;
    if(timer<POLL_LIMIT) timer<=timer+1;
    // Never withdraw an AXI request. A stalled bus remains owned until response.
    if(bus==0 && !response) begin
     if(missed_window && state<89) begin
       error<=14;state<=89;late_window<=0;
     end else if(missed_arm && state<89) begin error<=12;state<=89;end
     else if(readout_overrun && state<89) begin error<=13;state<=89;end
     else if(!calibrated[1] && state<89) begin error<=8;state<=89;end
     else if(timer==POLL_LIMIT && state<89) begin error<=3;state<=89;end
     else case(state)
      1:begin write_reg(dma_base+32'h0030,4);state<=2;end
      2:begin read_reg(dma_base+32'h0030);state<=3;end
      3:if(readback[2]) state<=2;else begin
         timer<=0;
         if(!sensor) begin sensor<=1;state<=1;end else begin sensor<=0;state<=5;end
        end
      5:begin
         timer<=0;
         if(stop_request && !exposure_pending) state<=89;
         // Once the grouped SPI transaction has latched its target, arm
         // both DMA receivers in parallel so the next SOF cannot overtake it.
         else if(spi_state==0 && window_known &&
                 (window_roi==want_roi || (late_window && write_window && spi_delay==0))) begin
           roi<=want_roi;state<=30;
         end
        end
      30:begin
         reserved_offset<=candidate;reserved_id<=next_frame_id;scan_index<=0;
         if(allocation>BUFFER_BYTES || id_exhausted) begin error<=11;state<=89;end
         else begin
          if(next_frame_id==32'hFFFFFFFF) id_exhausted<=1;
          else next_frame_id<=next_frame_id+1;
          state<=31;
         end
        end
      // Invalidate every overwritten frame BEFORE either DMA can write.
      // A large F may overlap several old ROI records after wrap.
      31:begin
         if(lut_valid[scan_index] &&
            {1'b0,frame_offsets[scan_index]} < {1'b0,reserved_offset}+allocation &&
            {1'b0,reserved_offset} < {1'b0,frame_offsets[scan_index]}+frame_lengths[scan_index]+128)
           lut_valid[scan_index]<=0;
         if(scan_index==255) begin lut_valid[lut_write]<=0;state<=10;end
         else scan_index<=scan_index+1;
        end
      10:begin write_reg(cap_base+32'h0000,roi ? 256 : 0);timer<=0;state<=11;end
      11:if(timer>=RESET_WAIT) state<=13;
      13:begin write_reg(dma_base+32'h0034,32'h7000);state<=14;end
      14:begin write_reg(dma_base+32'h0030,1);state<=15;end
      15:begin write_reg(dma_base+32'h004C,frame_address[63:32]);state<=16;end
      16:begin write_reg(dma_base+32'h0048,frame_address[31:0]);state<=17;end
      17:begin write_reg(dma_base+32'h0058,frame_bytes);state<=18;end
      18:begin write_reg(cap_base+32'h0000,roi ? 259 : 3);state<=19;end
      19:begin read_reg(cap_base+32'h0008);state<=20;end
      20:if(readback[0]) begin
         if(!sensor) begin sensor<=1;state<=10;end else begin sensor<=0;state<=21;end
        end else state<=19;
      21:begin
         timer<=0;
         if(exposure_pending) begin
           edges_before_trigger<=pending_edges;reserved_tick<=pending_tick;
           exposure_pending<=0;state<=22;
         end else if(stop_request) state<=89;
        end
      22:begin read_reg(dma_base+32'h0034);state<=23;end
      23:begin
       last_dma<=readback;
       if((readback&32'h770)!=0) begin error<=4;state<=89;end
       else state<=24;
      end
      24:begin read_reg(cap_base+32'h0008);state<=25;end
      25:begin
       last_cap<=readback;
       if((readback&32'h38)!=0) begin error<=5;state<=89;end
       else if((readback&32'h44)==32'h44 && (last_dma&32'h1002)==32'h1002) state<=26;
       else state<=22;
      end
      26:begin read_reg(dma_base+32'h0058);state<=35;end
      35:if(readback!=frame_bytes) begin error<=6;state<=89;end
         else if(!sensor) begin sensor<=1;state<=22;end
         else if (!pulse_valid[{1'b0,edges_before_trigger[0]}] ||
                  !pulse_valid[{1'b1,edges_before_trigger[1]}]) state<=35;
         else if (pulse_start[{1'b0,edges_before_trigger[0]}]!=pulse_start[{1'b1,edges_before_trigger[1]}] || pulse_end[{1'b0,edges_before_trigger[0]}]!=pulse_end[{1'b1,edges_before_trigger[1]}]) begin error<=9;state<=89;end
         else begin
          // Publish one stereo record only after BOTH DMA/checker completions.
          frame_rise[lut_write]<=pulse_start[{1'b0,edges_before_trigger[0]}];
          frame_fall[lut_write]<=pulse_end[{1'b0,edges_before_trigger[0]}];
          frame_ticks[lut_write]<=reserved_tick;
          frame_ids[lut_write]<=reserved_id;frame_offsets[lut_write]<=reserved_offset;
          frame_lengths[lut_write]<=frame_bytes;frame_rois[lut_write]<=roi;
          frame_seeds[lut_write]<=(7+(roi?503:0)+37*(roi?roi_count:full_count))&1023;
          lut_valid[lut_write]<=1;lut_write<=lut_write+1;
          write_offset<=reserved_offset+allocation;
          completed<=completed+1;timer<=0;sensor<=0;
          sequence_slot<=sequence_slot==ratio ? 0 : sequence_slot+1;
          if(roi) begin
           roi_budget_known<=1;
           if(counter-pulse_end[{1'b0,edges_before_trigger[0]}] >= SLOT_CYCLES-350*TICKS_PER_US)
             roi_budget_ok<=0;
           roi_count<=roi_count+1;
          end else begin
           full_count<=full_count+1;
          end
          if(completed==32'hFFFFFFFE) stop_request<=1;
          state<=5;
         end
      89:begin sensor<=0;state<=90;end
      90:begin write_reg(cap_base+32'h0000,4);state<=92;end
      92:begin write_reg(dma_base+32'h0030,4);state<=93;end
      93:begin read_reg(dma_base+32'h0030);state<=94;end
      94:if(readback[2]) state<=93;else begin
         if(!sensor) begin sensor<=1;state<=90;end else begin
         state<=95;
         end end
      95:if(recovery_window_safe && spi_state==0 && window_known && !window_roi) begin
         running<=0;done<=error==0;stopped<=stop_request;state<=0;
        end
      default:begin error<=7;state<=89;end
     endcase
    end

   end
  end
 end
endmodule
