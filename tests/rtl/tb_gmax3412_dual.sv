`timescale 1ns/1ps
module tb_gmax3412_dual;
 parameter LIVE=1, LIVE_R=24, EXPOSURE=1000, FAULT=0;
 parameter [31:0] PULSE_BASE=0;
 reg clk=0;always #4 clk=~clk;
 reg resetn=0,calib_ready=1;reg [31:0] control=0;wire [31:0] status;
 wire [31:0] awaddr,wdata,araddr;wire awvalid,wvalid,arvalid,bready,rready,trigger_pair,readout_pair;
 reg awready=0,wready=0,arready=0,bvalid=0,rvalid=0;
 reg [1:0] bresp=0,rresp=0;reg [31:0] rdata=0;
 wire [2:0] awprot,arprot;wire [3:0] wstrb;
 gmax3412_dual_ring #(.RESET_WAIT(12),.POLL_LIMIT(200000),.TICKS_PER_US(1),.IMAGE_WIDTH(16),.BUFFER_BYTES(32'd262144)) dut(.*,
 .m_axi_awaddr(awaddr),.m_axi_awprot(awprot),.m_axi_awvalid(awvalid),.m_axi_awready(awready),
 .m_axi_wdata(wdata),.m_axi_wstrb(wstrb),.m_axi_wvalid(wvalid),.m_axi_wready(wready),
 .m_axi_bresp(bresp),.m_axi_bvalid(bvalid),.m_axi_bready(bready),
 .m_axi_araddr(araddr),.m_axi_arprot(arprot),.m_axi_arvalid(arvalid),.m_axi_arready(arready),
 .m_axi_rdata(rdata),.m_axi_rresp(rresp),.m_axi_rvalid(rvalid),.m_axi_rready(rready));
 integer tick=0,pairs=0,delay_count=0,s,j,idx,inj=0,failed_sensor=0;
 reg gota=0,gotw=0;reg [31:0] a,d;
 reg [31:0] lo[2],hi[2],seed[2],mode[2],length[2];
 integer frames[2];reg [1:0] enabled=0,armed=0,finished=0;
 reg [63:0] expected;
 integer expected_offset=0,allocation_offset=0,allocations=0;
 integer saved_offset[128],saved_bytes[128];
 reg [31:0] expected_tick[128];
 reg [31:0] pulse_count=0;
 integer accepted_count=0;
 reg [15:0] ddr[2][131072];
 reg [1:0] cfg_wr=0;reg [7:0] cfg_addr=0;reg [31:0] cfg_data[2];wire [1:0] cfg_ok;
 wire [31:0] seq_rdata[2];reg overlap_seen=0;
 task cfg(input [7:0] address,input [31:0] value0,input [31:0] value1);
 begin @(negedge clk);cfg_addr=address;cfg_data[0]=value0;cfg_data[1]=value1;cfg_wr=3;
 @(negedge clk);cfg_wr=0;end
 endtask
 integer last_trigger=-1;
 reg src_init=0,src_start=0;reg [1:0] src_stop=0;
 reg [31:0] capture_control[2];
 wire [31:0] capture_status[2],source_status[2],checked[2],pixel_errors[2],accepted[2],rejected[2];
 wire [1:0] fvals,exposures;
 genvar g;
 generate for(g=0;g<2;g=g+1)begin: pipelines
  wire lv,seq_enable,source_armed,busy,pass,pending,flash,roi;
  wire [191:0] pixels;wire [9:0] active_seed;wire [7:0] analog;wire [15:0] digital;
  wire [31:0] npix,nlines,sum,skips,fault;
  wire [255:0] data;wire [31:0] keep;wire valid,last;
  wire ready=armed[g] && tick%200!=0;
  integer received=0,k,want,exposure_ticks=0;
  reg prev_fv=0,verify_roi;reg [9:0] verify_seed;
  gmax3412_sequence #(.WIDTH(16),.FOT_LINES(1000)) model(.clk(clk),.resetn(resetn),.init_cmd(src_init),.start_cmd(src_start),
   .stop_cmd(src_stop[g]),.trigger_cmd(trigger_pair),.readout_cmd(readout_pair),
   .wr(cfg_wr[g]),.addr(cfg_addr),.raddr(araddr[7:0]),.wdata(cfg_data[g]),.rdata(seq_rdata[g]),.write_ok(cfg_ok[g]),
   .blank_cycles(32'd1),.enabled(seq_enable),.armed(source_armed),.read_busy(busy),.pending(pending),
   .exposing(exposures[g]),.flash(flash),.fval(fvals[g]),.lval(lv),.pixels(pixels),.active_seed(active_seed),
   .active_roi(roi),.analog_gain(analog),.digital_gain(digital),.accepted(accepted[g]),.rejected(rejected[g]),
   .skipped(skips),.fault(fault),.checked(checked[g]),.check_errors(pixel_errors[g]),.last_pixels(npix),
   .last_lines(nlines),.checksum(sum),.last_pass(pass));
  assign source_status[g]={27'b0,pass,exposures[g],busy,source_armed,1'b1};
  gmax3412_capture #(.WIDTH(16),.LANES(16),.AXIS_WIDTH(256),.DEPTH(4096)) bridge(
   .clk(clk),.resetn(resetn),.control(capture_control[g]),.status(capture_status[g]),
   .emu_clk(clk),.emu_fval(fvals[g]),.emu_lval(lv),.emu_data(pixels),
   .rx_clk(clk),.rx_fval(1'b0),.rx_lval(1'b0),.rx_data(192'b0),
   .m_axis_tdata(data),.m_axis_tkeep(keep),.m_axis_tvalid(valid),.m_axis_tready(ready),.m_axis_tlast(last));
  always @(posedge clk)begin
   prev_fv<=fvals[g];
   if(fvals[g] && !prev_fv) begin verify_seed<=active_seed;verify_roi<=roi;end
   if(exposures[g])exposure_ticks++;
   else if(exposure_ticks!=0)begin
    // Explicit fault abort may truncate an uncommitted exposure.
    if(dut.error==0 && exposure_ticks!=EXPOSURE)$fatal(1,"Incorrect TEXP pulse width");
    exposure_ticks=0;
   end
   if(!armed[g] || !capture_control[g][0])received=0;
   if(exposures[g] && fvals[g])overlap_seen=1;
   if(flash && !exposures[g])$fatal(1,"Flash outside exposure");
   if(valid&&ready)begin
    if(keep!=32'hFFFFFFFF)$fatal(1,"Pair stream keep");
    for(k=0;k<16;k++)begin
     want=((received+k)%16+(received+k)/16+(verify_roi?1024:0)+
           (((received+k)/16+(verify_roi?1024:0))>>10)*17+verify_seed)&1023;
     if(data[k*16+:16]!==want[15:0])$fatal(1,"Pair pixel/ROI row sensor %d offset %d",g,received+k);
    end
    for(k=0;k<16;k++) begin
     if((lo[g]-(g?32'h80000000:0))/2+received+k>=131072)$fatal(1,"DDR aperture escape");
     ddr[g][(lo[g]-(g?32'h80000000:0))/2+received+k]=data[k*16+:16];
    end
    received+=16;
    if(last!==(received*2==length[g]))$fatal(1,"Pair stream TLAST");
    if(last)finished[g]<=1;
   end
  end
 end endgenerate
 // Fault recovery stops the two AXI-controlled sensors sequentially.
 // Require stereo alignment throughout acquisition, before fault shutdown.
 always @(negedge clk)if(LIVE && resetn && dut.error==0 && (fvals[0]!==fvals[1] || exposures[0]!==exposures[1]))
  $fatal(1,"Stereo frame/exposure skew");
 always @(negedge clk) begin
  tick=tick+1;awready=(tick%3==0);wready=(tick%4==0);arready=(tick%5==0);
 end
 always @(posedge clk) if(resetn) begin
  src_stop<=0;
  if(awvalid&&awready) begin a<=awaddr;gota<=1;end
  if(wvalid&&wready) begin d<=wdata;gotw<=1;end
  if(bvalid&&bready)bvalid<=0;
  if(rvalid&&rready)rvalid<=0;
  if(gota&&gotw&&!bvalid) begin
   gota<=0;gotw<=0;bvalid<=1;bresp<=0;
   s=(a>=32'hA0080000)?1:0;
   case(a & 32'hFFFF)
    'h64:mode[s]<=d;
    'h14:seed[s]<=d;
    'h00:begin capture_control[s]<=d;enabled[s]<=d[0];if(!d[0])finished[s]<=0;end
    'h04:if(d==4)src_stop[s]<=1;
    'h30:if(d==4)armed[s]<=0;
    'h48:lo[s]<=d;
    'h4C:hi[s]<=d;
    'h58:begin
      length[s]<=d;armed[s]<=1;
      if(d!=(dut.roi?32768:98304))$fatal(1,"DMA length");
      idx=dut.roi?1:0;
      if(s==0)allocation_offset=(expected_offset+d+128>262144)?0:expected_offset;
      expected=64'h1000000040+s*64'h80000000+allocation_offset;
      if(s==1)begin
       saved_offset[allocations]=allocation_offset;saved_bytes[allocations]=d;
       allocations++;expected_offset=allocation_offset+d+128;
      end
      if({hi[s],lo[s]}!=expected || dut.reserved_offset+d+128>262144)$fatal(1,"ordered buffer address");
      // All overlapping old records must be invalid BEFORE DMA receives length.
      for(integer q=0;q<256;q++)if(dut.lut_valid[q] &&
        dut.frame_offsets[q]<dut.reserved_offset+d+128 &&
        dut.reserved_offset<dut.frame_offsets[q]+dut.frame_lengths[q]+128)
          $fatal(1,"Stale lookup visible during overwrite");
    end
    default:begin end
   endcase
  end
  if(trigger_pair) begin
   pulse_count=pulse_count+1;
   if(dut.trigger_slots!=pulse_count)$fatal(1,"Timer generator pulse count");
   if(pipelines[0].source_armed && !pipelines[0].model.integration && !pipelines[0].busy)begin
    expected_tick[accepted_count]=pulse_count;accepted_count++;
   end
   if(last_trigger>=0 && tick-last_trigger!=4000)$fatal(1,"Nonuniform 250 Hz timer");
   last_trigger=tick;
  end
  if(readout_pair)begin
   if(armed!=3||enabled!=3)$fatal(1,"Readout before both capture paths ready");
   idx=dut.roi?1:0;
   if(idx!=(pairs%(LIVE_R+1)!=0))$fatal(1,"Readout LUT sequence");
   pairs=pairs+1;frames[idx]=frames[idx]+1;
  end
  if(!LIVE && delay_count>0)begin delay_count=delay_count-1;if(delay_count==1 && inj!=3)finished<=3;end
  if(arvalid&&arready)begin
   rvalid<=1;rresp<=0;s=(araddr>=32'hA0080000)?1:0;
   case(araddr & 32'hFFFF)
    'hb8,'h88,'h8c:rdata<=seq_rdata[s];
    'h28:rdata<=checked[s];
    'h30:rdata<=0;
    'h34:rdata<=inj==1 && s==failed_sensor ? 'h10 : (finished[s]?'h1002:0);
    'h08:if(araddr==32'hA0030008||araddr==32'hA0080008)rdata<=LIVE?source_status[s]:'h13;
          else rdata<=LIVE?capture_status[s]:inj==2 && pairs>0 && s==failed_sensor?'h1A:(finished[s]?'h47:(enabled[s]?3:0));
    default:$fatal(1,"Unexpected read");
   endcase
   if(inj==4 && pairs>0)begin rresp<=2;inj=0;end
  end
 end
 task cmd(input [2:0] op,input [19:0] n);
 begin @(negedge clk);control={~control[31],op,n,8'b0};repeat(4)@(negedge clk);end
 endtask
 task bank(input [3:0] n);
 begin @(negedge clk);control[3:0]=n;#1;end
 endtask
 task reset_run;
 begin
  @(negedge clk);resetn=0;control=0;repeat(8)@(negedge clk);resetn=1;
  capture_control[0]=0;capture_control[1]=0;frames[0]=0;frames[1]=0;pairs=0;last_trigger=-1;enabled=0;armed=0;finished=0;
  repeat(8)@(negedge clk);
 end
 endtask
 task await_stop;
 integer limit;
 begin bank(1);limit=0;while(status[0]&&limit<(LIVE?5000000:100000))begin @(negedge clk);limit++;end
  if(status[0])$fatal(1,"stop timeout");
  if(armed||enabled)$fatal(1,"Cleanup did not release BOTH paths");
 end
 endtask
 initial begin
  reset_run();cfg(8'h70,1,1);cfg(8'h98,7,120);
  for(integer n=0;n<256;n++)begin
   cfg(8'h74,n,n);cfg(8'h78,EXPOSURE,EXPOSURE);
   cfg(8'h7c,(18<<1)|1,(18<<1)|1);
   cfg(8'h80,n%(LIVE_R+1)!=0,n%(LIVE_R+1)!=0);
  end
  cfg(8'h84,1|((LIVE_R+1)<<8),1|((LIVE_R+1)<<8));
  @(negedge clk);src_init=1;@(negedge clk);src_init=0;src_start=1;@(negedge clk);src_start=0;
  if(FAULT==2)dut.next_frame_id=32'hFFFFFFFE;
  cmd(1,LIVE_R);cmd(2,0);
  // Before the first timer pulse: exercise upper bits and modulo rollover.
  dut.trigger_slots=PULSE_BASE;pulse_count=PULSE_BASE;
  pipelines[0].model.slot_id=PULSE_BASE;pipelines[1].model.slot_id=PULSE_BASE;
  if(FAULT!=0)begin
   if(FAULT==1) begin wait(accepted[0]==1);inj=1;failed_sensor=1;end
   await_stop();
   if(!status[2] || dut.error!=(FAULT==1?4:11))$fatal(1,"Expected fault not reported");
   if(FAULT==1 && (dut.lut_valid!=0 || dut.completed!=0))$fatal(1,"Partial stereo pair was published");
   if(FAULT==2 && (!dut.id_exhausted || dut.completed!=2 ||
      dut.frame_ids[0]!=32'hFFFFFFFE || dut.frame_ids[1]!=32'hFFFFFFFF))$fatal(1,"FrameID exhaustion/reuse");
   $display("DUAL_FAULT_PASS: case=%0d, no partial publication or FrameID rollover",FAULT);$finish;
  end
  wait(accepted[0]==1);
  // Active reads continue while port A edits the inactive bank. Commit is denied.
  cfg(8'h74,0,0);cfg(8'h78,0,0);
  @(negedge clk);cfg_addr=8'h84;#1;if(cfg_ok!=0)$fatal(1,"Live commit accepted");
  cfg(8'h84,1,1);
  wait(accepted[0]>=(LIVE_R==24?27:(LIVE_R==0?6:4)));cmd(3,0);await_stop();
  if(status[2]||!status[1]||pairs!=accepted[0]||accepted[0]!=accepted[1])$fatal(1,"Drain/count failure status=%h error=%d pairs=%d accepted=%d",status,dut.error,pairs,accepted[0]);
  if(overlap_seen)$fatal(1,"Exposure/readout overlap forbidden");
  if(EXPOSURE>=4000 && pipelines[0].skips==0)$fatal(1,"Long exposure did not skip slots");
  if((dut.trigger_slots-PULSE_BASE)!=accepted[0]+pipelines[0].skips)$fatal(1,"Timer slot accounting");
  for(integer sensor=0;sensor<2;sensor++)
   if(checked[sensor]!=pairs||pixel_errors[sensor]!=0||rejected[sensor]!=0)$fatal(1,"Source checker/counters");
  for(integer q=0;q<256;q++)if(dut.lut_valid[q])begin
   if(dut.frame_ids[q]>=allocations || dut.frame_offsets[q]!=saved_offset[dut.frame_ids[q]] ||
      dut.frame_lengths[q]!=saved_bytes[dut.frame_ids[q]])$fatal(1,"FrameID/address history");
   for(integer ss=0;ss<2;ss++)for(integer pixel=0;pixel<dut.frame_lengths[q]/2;pixel++) begin
    if(ddr[ss][(dut.frame_offsets[q]+64)/2+pixel]!==
       ((pixel%16+pixel/16+(dut.frame_rois[q]?1024:0)+
       ((pixel/16+(dut.frame_rois[q]?1024:0))>>10)*17+
       ((dut.frame_seeds[q]+ss*113)&1023))&1023))$fatal(1,"Retained DDR pixels by FrameID");
   end
   cmd(6,q);bank(2);if(status!=dut.frame_ids[q])$fatal(1,"FrameID lookup");
   bank(10);if(status!=expected_tick[dut.frame_ids[q]])$fatal(1,"Stored timer pulse association");
   bank(3);if(status!=dut.frame_offsets[q]+64)$fatal(1,"Address lookup");
   bank(6);if(status!=dut.frame_lengths[q])$fatal(1,"Length lookup");
   bank(7);if(status!={30'b0,dut.frame_rois[q],1'b1})$fatal(1,"Validity lookup");
  end
  cmd(7,0);
  if(pipelines[0].model.extended_frames || pipelines[1].model.extended_frames ||
     pipelines[0].model.extension_cycles || pipelines[1].model.extension_cycles)$fatal(1,"Exposure extension forbidden");
  $display("DUAL_LIVE_PASS: R=%0d exposure=%0d, %0d stereo frames, overlap=%0d, skipped=%0d, ordered DDR wrap/overlap invalidation/FrameID lookup, 32-bit TimerPulse LUT association, zero exposure extension, middle ROI pixels, FV capture, exact timer, DMA framing, drain",LIVE_R,EXPOSURE,pairs,overlap_seen,pipelines[0].skips);
  $finish;
 end
 initial begin #20000000;$fatal(1,"Watchdog state=%d error=%d accepted=%d readout=%d",dut.state,dut.error,accepted[0],pairs);end
endmodule
