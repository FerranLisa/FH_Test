`timescale 1ns/1ps
// Rolling PL DDR4 capture. GPIO command/status interface; AXI-Lite control master.
// Storage is fixed to reserved DDR apertures; software cannot supply DMA addresses.
module gmax3412_dual_ring #(parameter RESET_WAIT=128, POLL_LIMIT=240000000, TICKS_PER_US=120,
 IMAGE_WIDTH=4096,IMAGE_HEIGHT=3072,ROI_HEIGHT=1024, BUFFER_BYTES=32'h80000000)(
 (* X_INTERFACE_PARAMETER="ASSOCIATED_BUSIF M_AXI, ASSOCIATED_RESET resetn, FREQ_HZ 120000000" *) input wire clk,
 (* X_INTERFACE_PARAMETER="POLARITY ACTIVE_LOW" *) input wire resetn,
 input wire calib_ready,
 output reg trigger_pair, readout_pair,
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
 wire [31:0] allocation=frame_bytes+128;
 wire [31:0] candidate=({1'b0,write_offset}+allocation>BUFFER_BYTES)?0:write_offset;

 
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
 wire [31:0] frame_bytes=IMAGE_WIDTH*(roi ? ROI_HEIGHT : IMAGE_HEIGHT)*2;
 wire [31:0] frame_seed=(7 + (sensor ? 113 : 0) + (roi ? 503 : 0) +
                           37*(roi ? roi_count : full_count)) & 1023;
 reg toggle, running, done, stopped, stop_request;
 reg [7:0] state;
 reg [31:0] completed;
 (* ASYNC_REG="TRUE" *) reg [1:0] calibrated;
 always @(posedge clk) if(!resetn) calibrated<=0; else calibrated<={calibrated[0],calib_ready};
 reg [31:0] error, timer, cycles, last_dma, last_cap;
 reg [1:0] bus;
 reg response;
 reg [31:0] readback;
 wire command=control[31]!=toggle;
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
    14:status=frame_address[31:0];15:status={30'b0,sensor,roi};
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
 end
 always @(posedge clk) begin
  if(!resetn) begin
   write_offset<=0;reserved_offset<=0;next_frame_id<=0;reserved_id<=0;id_exhausted<=0;
   lut_write<=0;scan_index<=0;lut_valid<=0;lookup_mode<=0;
   query_tick<=0;reserved_tick<=0;query_id<=0;query_offset<=0;query_length<=0;query_seed<=0;query_valid<=0;query_roi<=0;
   trigger_pair<=0;exposure_left<=0;readout_pair<=0;head_a<=0;source_a<=0;source_b<=0;sensor<=0;roi<=0;
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
   else trigger_pair<=0;
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
     6:begin
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
     2:if(!running && error==0 && calibrated[1] && !id_exhausted) begin
        begin
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
    cycles<=cycles+1;
    if(epoch) begin
     slot_ticks<=slot_ticks+1;
     if(slot_ticks==next_trigger && !stop_request && error==0 && state<89) begin
      trigger_slots<=trigger_slots+1;next_trigger<=next_trigger+SLOT_CYCLES;
     end
    end
    if(sub_us==TICKS_PER_US-1) begin sub_us<=0;usec<=usec+1;end else sub_us<=sub_us+1;
    if(timer<POLL_LIMIT) timer<=timer+1;
    // Never withdraw an AXI request. A stalled bus remains owned until response.
    if(bus==0 && !response) begin
     if(!calibrated[1] && state<89) begin error<=8;state<=89;end
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
         if(stop_request) state<=89;
         else begin roi<=sequence_slot!=0;state<=30;end
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
         if(stop_request) state<=89;
         else if(!epoch || slot_ticks==next_trigger) begin
           if(!epoch) begin epoch<=1;slot_ticks<=1;next_trigger<=SLOT_CYCLES;trigger_slots<=1;end
           reserved_tick<=trigger_slots+1;
           trigger_pair<=1;exposure_left<=exposure_us*TICKS_PER_US-1;state<=22;
         end
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
         else begin
          // Publish one stereo record only after BOTH DMA/checker completions.
          frame_ticks[lut_write]<=reserved_tick;
          frame_ids[lut_write]<=reserved_id;frame_offsets[lut_write]<=reserved_offset;
          frame_lengths[lut_write]<=frame_bytes;frame_rois[lut_write]<=roi;
          frame_seeds[lut_write]<=(7+(roi?503:0)+37*(roi?roi_count:full_count))&1023;
          lut_valid[lut_write]<=1;lut_write<=lut_write+1;
          write_offset<=reserved_offset+allocation;
          completed<=completed+1;timer<=0;sensor<=0;
          sequence_slot<=sequence_slot==ratio ? 0 : sequence_slot+1;
          if(roi) begin
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
         running<=0;done<=error==0;
         stopped<=stop_request;state<=0;
         end end
      default:begin error<=7;state<=89;end
     endcase
    end

   end
  end
 end
endmodule
