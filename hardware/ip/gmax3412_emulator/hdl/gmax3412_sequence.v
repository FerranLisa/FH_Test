`timescale 1ns/1ps
// Dual-port, double-bank parameter tables and independent exposure/readout FSMs.
// Port A: software accesses the inactive bank. Port B: frame-side snapshots.
module gmax3412_sequence #(
 parameter WIDTH=4096, HEIGHT=3072, ROI_HEIGHT=1024, ROI_START=1024,
 parameter LANES=16, FOT_LINES=21, EXTRA_ROWS=12
)(
 input wire clk,resetn,init_cmd,start_cmd,stop_cmd,trigger_cmd,readout_cmd,
 input wire wr, input wire [7:0] addr,raddr, input wire [31:0] wdata,
 output reg [31:0] rdata, output wire write_ok,
 input wire [31:0] blank_cycles,
 output reg enabled,armed,exposing,flash,read_busy, output wire pending,
 output reg fval,lval,output reg [12*LANES-1:0] pixels,
 output reg [9:0] active_seed,output reg active_roi,
 output reg [7:0] analog_gain,output reg [15:0] digital_gain,
 output reg [31:0] accepted,rejected,skipped,fault,
 output wire [31:0] checked,check_errors,last_pixels,last_lines,checksum,
 output wire last_pass
);
 (* ram_style="distributed" *) reg [31:0] exposure_lut[0:511];
 (* ram_style="distributed" *) reg [24:0] capture_lut[0:511];
 (* ram_style="distributed" *) reg readout_lut[0:511];
 reg bank=0;reg [7:0] index=0,cap_length=1,ro_length=25,cap_index=0,ro_index=0;
 wire [8:0] sw_address={!bank,index};
 wire [8:0] cap_address={bank,cap_index},ro_address={bank,ro_index};
 reg [31:0] exposure_timer,full_sequence,roi_sequence;
 // One-based timer pulse count, including rejected busy slots; wraps modulo 2^32.
 reg [31:0] slot_id,exposure_slot;
 reg exposure_roi;reg [9:0] exposure_seed;
 // One integrating image and one storage/readout image. No completed-image FIFO.
 reg integration,prepared,extended_this;
 reg [31:0] descriptor;
 reg [24:0] exposure_parameters,read_parameters;
 reg [31:0] exposure_setting,read_exposure,extended_frames,extension_cycles;
 reg [31:0] overhead;
 wire finish_exposure=integration && !exposing && !read_busy;
 wire [31:0] line_cycles=WIDTH/LANES+(blank_cycles?blank_cycles:1);
 reg [15:0] x,y;
 reg [31:0] blank_timer;
 reg [2:0] read_state;
 integer i,n;
 // FPGA power-up initialization; resetting acquisition does not erase tables.
 initial for(n=0;n<512;n=n+1) begin
  exposure_lut[n]=120000;
  capture_lut[n]=(25'h12<<1)|1; // flash enabled, PGA unity, digital unity
  readout_lut[n]=(n%256)%25!=0;
 end
 assign write_ok=(addr==8'h74 || addr==8'h78 || addr==8'h7c || addr==8'h80 ||
                  ((addr==8'h70 || addr==8'h84 || addr==8'h98) && !armed && !exposing && !read_busy && !integration));
 reg [9:0] seed_base;
 always @* begin
  case(raddr)
   8'h70:rdata={31'b0,enabled};
   8'h74:rdata={24'b0,index};
   8'h78:rdata=exposure_lut[sw_address];
   8'h7c:rdata={7'b0,capture_lut[sw_address]};
   8'h80:rdata={31'b0,readout_lut[sw_address]};
   8'h84:rdata={16'b0,ro_length,cap_length};
   8'h88:rdata=pending ? descriptor : 0;
   8'h8c:rdata={25'b0,integration,(read_state==4),last_pass,armed,(exposing|integration),(fault!=0),read_busy};
   8'h90:rdata=skipped;
   8'h94:rdata=fault;
   8'h98:rdata={22'b0,seed_base};
   8'h9c:rdata={8'b0,digital_gain,analog_gain};
   8'ha0:rdata={7'b0,read_parameters};
   8'ha4:rdata=read_exposure;
   8'ha8:rdata=active_roi?ROI_START:0;
   8'hb8:rdata=exposure_slot; // Latched at acceptance, stable until next accepted pulse.
   8'hac:rdata=active_roi?ROI_HEIGHT:HEIGHT;
   8'hb0:rdata=extended_frames;
   8'hb4:rdata=extension_cycles;
   default:rdata=0;
  endcase
 end
 assign pending=integration || (read_state==4 && !prepared);
 always @(posedge clk) begin
  if(!resetn) begin
   enabled<=0;armed<=0;exposing<=0;flash<=0;read_busy<=0;fval<=0;lval<=0;pixels<=0;
   active_seed<=0;active_roi<=0;analog_gain<=8'h12;digital_gain<=0;
   accepted<=0;rejected<=0;skipped<=0;fault<=0;bank<=0;index<=0;cap_length<=1;ro_length<=25;
   cap_index<=0;ro_index<=0;exposure_timer<=0;full_sequence<=0;roi_sequence<=0;
   slot_id<=0;exposure_slot<=0;exposure_roi<=0;exposure_seed<=0;
   integration<=0;prepared<=0;extended_this<=0;extended_frames<=0;extension_cycles<=0;overhead<=0;descriptor<=0;exposure_parameters<=0;x<=0;y<=0;blank_timer<=0;read_state<=0;seed_base<=7;
   exposure_setting<=0;read_parameters<=0;read_exposure<=0;
  end else begin
   lval<=0;
   if(wr && write_ok) case(addr)
    8'h70:enabled<=wdata[0];
    8'h74:index<=wdata[7:0];
    8'h78:exposure_lut[sw_address]<=wdata;
    8'h7c:capture_lut[sw_address]<=wdata[24:0];
    8'h80:readout_lut[sw_address]<=wdata[0];
    8'h84:begin bank<=!bank;cap_length<=wdata[7:0];ro_length<=wdata[15:8];end
    8'h98:seed_base<=wdata[9:0];
   endcase
   if(init_cmd && !armed && !exposing && !read_busy && !integration) begin
    cap_index<=0;ro_index<=0;full_sequence<=0;roi_sequence<=0;slot_id<=0;fault<=0;extended_frames<=0;extension_cycles<=0;
   end
   if(start_cmd && enabled && !fault) armed<=1;
   if(stop_cmd) armed<=0;
   if(exposing) begin
    if(exposure_timer==1) begin exposing<=0;flash<=0;end
    else exposure_timer<=exposure_timer-1;
   end
   // Discard every busy timer tick: exposure, FOT, pixels, blanking and FRD tail.
   if(trigger_cmd && armed && !stop_cmd && !fault) begin
    slot_id<=slot_id+1;
    // Preserve a real low interval between TEXP pulses, including the exact
    // 4 ms boundary; a finishing exposure still owns this trigger edge.
    if(integration || exposing || read_busy) skipped<=skipped+1;
    else if(exposure_lut[cap_address]==0) begin fault<=1;rejected<=rejected+1;armed<=0;end
    else begin
     exposing<=1;integration<=1;prepared<=0;extended_this<=0;exposure_timer<=exposure_lut[cap_address];
     exposure_parameters<=capture_lut[cap_address];
     descriptor<={slot_id[15:0],10'b0,4'b0,readout_lut[ro_address],1'b1};
     exposure_setting<=exposure_lut[cap_address];
     flash<=capture_lut[cap_address][0];
     analog_gain<=capture_lut[cap_address][8:1];digital_gain<=capture_lut[cap_address][24:9];
     exposure_roi<=readout_lut[ro_address];exposure_slot<=slot_id+1;
     exposure_seed<=(seed_base+(readout_lut[ro_address]?503:0)+
                      37*(readout_lut[ro_address]?roi_sequence:full_sequence))&1023;
     if(readout_lut[ro_address]) roi_sequence<=roi_sequence+1;else full_sequence<=full_sequence+1;
     accepted<=accepted+1;
     cap_index<=(cap_index+8'd1==cap_length)?0:cap_index+8'd1;
     ro_index<=(ro_index+8'd1==ro_length)?0:ro_index+8'd1;
    end
   end
   // Readout command acknowledges receiver preparation; it cannot delay FV.
   if(readout_cmd && (integration || read_state==4)) prepared<=1;
   if(integration && !exposing && read_busy) begin
    fault<=4;armed<=0; // Invariant failure: never accept this as normal operation.
    extension_cycles<=extension_cycles+1;
    if(!extended_this) begin extended_this<=1;extended_frames<=extended_frames+1;end
   end
   // Admission excludes readout overlap; exposure extension is a protocol fault.
   if(finish_exposure) begin
    integration<=0;read_busy<=1;read_state<=4;
    overhead<=FOT_LINES*line_cycles;
    active_roi<=exposure_roi;active_seed<=exposure_seed;
    read_parameters<=exposure_parameters;read_exposure<=exposure_setting;
    x<=0;y<=0;
   end
   case(read_state)
    4:if(overhead<=1) begin
       // Autonomous FV. Missing receiver readiness is an explicit error.
       fval<=1;read_state<=1;
       if(!prepared) begin fault<=3;armed<=0;end
      end else overhead<=overhead-1;
    1:begin
     lval<=1;
     for(i=0;i<LANES;i=i+1)
      pixels[12*i+:12]<=(x+i+y+(active_roi?ROI_START:0)+
         ((y+(active_roi?ROI_START:0))>>10)*17+active_seed)&1023;
     if(x==WIDTH-LANES) begin
      x<=0;
      if(y==(active_roi?ROI_HEIGHT:HEIGHT)-1) read_state<=3;
      else begin y<=y+1;blank_timer<=blank_cycles?blank_cycles:1;read_state<=2;end
     end else x<=x+LANES;
    end
    2:if(blank_timer==1)read_state<=1;else blank_timer<=blank_timer-1;
    3:begin fval<=0;overhead<=EXTRA_ROWS*line_cycles;read_state<=5;end
    5:if(overhead<=1) begin read_busy<=0;read_state<=0;end else overhead<=overhead-1;
   endcase
   if(stop_cmd) begin
    armed<=0;exposing<=0;flash<=0;integration<=0;prepared<=0;overhead<=0;
    read_state<=0;read_busy<=0;fval<=0;lval<=0;
   end
  end
 end
 gmax3412_checker #(.WIDTH(WIDTH),.HEIGHT(HEIGHT),.DYNAMIC_ROI(1),.LANES(LANES),
  .ROI_HEIGHT(ROI_HEIGHT),.ROI_START(ROI_START),.ROW_TAG(1)) check_frame(
  .clk(clk),.resetn(resetn),.fval(fval),.lval(lval),.data(pixels),.seed(active_seed),
  .roi_mode(active_roi),.frames(checked),.errors(check_errors),.last_pixels(last_pixels),
  .last_lines(last_lines),.checksum(checksum),.last_pass(last_pass));
endmodule
