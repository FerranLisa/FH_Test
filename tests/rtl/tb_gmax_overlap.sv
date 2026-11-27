`timescale 1ns/1ps
// Real scheduler and dual capture bridges. Reduced width (one 16-pixel beat
// per row by default); WIDTH=4096 exercises the native images. AXI peripherals model S2MM completion latency.
module tb_gmax_overlap;
  parameter FOT=650, LATE_SOF_FAULT=0, RATE=2, WIDTH=16, LONG_READOUT=0, EXP=3600;
  parameter ROW_GAP=1, TRACE_TRANSITIONS=0, DMA_DELAY=0, R=3, WINDOW_FAULT=0;
  localparam GROUPS=WIDTH/16, FRAME_COUNT=R+3;
  localparam FOT_BLOCKS_TICK=(EXP*RATE+FOT>=4000*RATE);
  reg clk=0, resetn=0;
  always #(500.0/RATE) clk=~clk;
  reg [31:0] ctrl=0, rdata=0;
  wire [31:0] aw,wd,ar;
  wire wv,rv,trigger;
  reg bvalid=0,rvalid=0;
  wire [3:0] spi;
  reg [1:0] fv=0,lv=0;
  reg [11:0] sample[2];
  reg [31:0] capctrl[2],length[2];
  wire [31:0] capstatus[2];
  integer tick=0,n=0,overlaps=0,tp_gaps=0,group_count=0,roi_groups=0;
  integer rises[FRAME_COUNT],falls[FRAME_COUNT],slots[FRAME_COUNT];
  reg [63:0] stamp[FRAME_COUNT];
  integer beats[2],received[2],dma_visible[2];
  reg [1:0] done=0;
  integer height=3072;
  reg [23:0] word_spi;
  always @(posedge spi[1]) if(spi[3] && !spi[2]) word_spi={word_spi[22:0],spi[0]};
  reg hold_window=0;
  integer staged_height, origin=0, staged_origin;
  always @(posedge spi[2]) if(spi[3]) case(word_spi[23:8])
    1:if(word_spi[0]) begin
        if(|fv) $fatal(1,"REG_HOLD asserted during readout");
        hold_window=1;staged_height=height;staged_origin=origin;group_count++;
      end else begin
        if(!hold_window || !trigger) $fatal(1,"Unexpected REG_HOLD release");
        hold_window=0;height=staged_height;origin=staged_origin;
        if(height==1024) begin
          roi_groups++;
          $display("FULL to ROI: release %0.3f us before TEXP fall",(EXP*RATE-(tick-rises[n-1]))*1.0/RATE);
        end
      end
    16'h1e:if(hold_window) staged_origin=word_spi[7:0]*256;else origin=word_spi[7:0]*256;
    16'h20:if(hold_window) staged_height=word_spi[7:0]*256;else height=word_spi[7:0]*256;
  endcase

  gmax3412_dual_ring #(.TICKS_PER_US(RATE),.RESET_WAIT(16),.IMAGE_WIDTH(WIDTH)) dut(
    .clk(clk),.resetn(resetn),.calib_ready(1'b1),.control(ctrl),.rtc_seconds_irq(1'b0),
    .rx_clk_a(clk),.rx_clk_b(clk),.fval_a(fv[0]),.fval_b(fv[1]),.lval_a(lv[0]),.lval_b(lv[1]),.texp_pins({2{trigger}}),.trigger_pair(trigger),.window_spi(spi),
    .m_axi_awaddr(aw),.m_axi_awready(1'b1),.m_axi_wdata(wd),.m_axi_wvalid(wv),
    .m_axi_wready(1'b1),.m_axi_bvalid(bvalid),.m_axi_bresp(2'b0),
    .m_axi_araddr(ar),.m_axi_arvalid(rv),.m_axi_arready(1'b1),.m_axi_rvalid(rvalid),
    .m_axi_rdata(rdata),.m_axi_rresp(2'b0));
  always @(posedge clk) tick<=tick+1;
  if(TRACE_TRANSITIONS) begin: trace
    always @(negedge fv[1]) if(n) $display("EOF frame=%0d us=%0.2f",n-1,(tick-rises[n-1])*1.0/RATE);
    always @(posedge spi[2]) if(n && dut.second_word) $display("SPI_END after=%0d us=%0.2f",n-1,(tick-rises[n-1])*1.0/RATE);
    always @(negedge spi[2]) if(n && !dut.second_word && (!dut.grouped || dut.spi_word==0))
      $display("SPI_START after=%0d us=%0.2f",n-1,(tick-rises[n-1])*1.0/RATE);
    always @(posedge clk) if(dut.epoch && !dut.stop_request && dut.slot_ticks==dut.next_trigger)
      $display("TICK %0d prev=%0d fv=%b state=%0d spi=%0d window=%b want=%b skip=%b pending=%b",dut.trigger_slots+1,n-1,fv,dut.state,dut.spi_state,dut.window_roi,dut.exposure_slot!=0,dut.skip_after_full,dut.exposure_pending);
  end
  always @(posedge trigger) begin
    if (|fv) begin
      if(fv!=3) $fatal(1,"Unexpected stereo skew");
      overlaps++;
    end
    if(n && tick<falls[n-1]+FOT && !LATE_SOF_FAULT) $fatal(1,"TEXP inside modeled FOT");
    rises[n]=tick; slots[n]=dut.pending_tick; n++;
  end
  always @(negedge trigger) if(n) begin
    if(!WINDOW_FAULT && (hold_window || height!=((n-1)%(R+1)==0?3072:1024) ||
       origin!=((n-1)%(R+1)==0?0:1024))) $fatal(1,"SPI window mismatch at TEXP fall");
    falls[n-1]=tick;
  end
  // Capture the expected timestamp at the actual synchronized edge.
  always @(posedge clk) if(dut.edge_sync[0] && !dut.edge_previous[0]) stamp[n-1]=dut.counter;
  for(genvar eye=0;eye<2;eye++) begin: eyes
    wire valid,last;
    wire [255:0] data;
    integer descriptor=0,row,rows,frame_no,start_count;
    gmax3412_capture #(.WIDTH(WIDTH),.DEPTH(64),.AXIS_WIDTH(256)) bridge(
      .clk(clk),.resetn(resetn),.control(capctrl[eye]),.status(capstatus[eye]),
      .emu_clk(clk),.emu_fval(1'b0),.emu_lval(1'b0),.emu_data(192'b0),
      .rx_clk(clk),.rx_fval(fv[eye]),.rx_lval(lv[eye]),.rx_data({16{sample[eye]}}),
      .m_axis_tdata(data),.m_axis_tvalid(valid),.m_axis_tlast(last),.m_axis_tready(1'b1));
    initial forever begin
      @(negedge trigger);
      if(n>0) begin
        rows=height;frame_no=n-1;
        repeat(FOT+eye) @(negedge clk);
        fv[eye]=1;start_count=n;
        for(row=0;row<rows;row++) begin
          if(n!=start_count) begin
            repeat(5*(GROUPS+ROW_GAP)) @(negedge clk); // five row periods without LVAL
            start_count=n;if(eye==0) tp_gaps++;
          end
          lv[eye]=1;
          for(integer group_no=0;group_no<GROUPS;group_no++) begin
            sample[eye]=(frame_no*17+row*GROUPS+group_no+eye)&4095;
            @(negedge clk);
          end
          lv[eye]=0;repeat(ROW_GAP) @(negedge clk);
        end
        if(LONG_READOUT && frame_no==1) repeat(8500) @(negedge clk);
        fv[eye]=0;
      end
    end
    always @(posedge clk) if(valid) begin
      if(data!=={16{4'b0,12'((descriptor*17+beats[eye]+eye)&4095)}}) $fatal(1,"pixel mismatch");
      beats[eye]++;
      if(last) begin
        if(32*beats[eye]!=length[eye]) $fatal(1,"DMA length mismatch");
        beats[eye]=0;received[eye]++;descriptor++;done[eye]<=1;
        dma_visible[eye]=tick+DMA_DELAY+
          (((WINDOW_FAULT==1 && descriptor==R+1) || (WINDOW_FAULT==2 && descriptor==1)) ? 2_000*RATE : 0);
      end
    end
  end
  reg [31:0] addr_lo[2], addr_hi[2];
  integer next_offset[2];
  integer e;
  always @(posedge clk) begin
    bvalid<=wv;rvalid<=rv;
    if(wv) begin
      e=aw>=32'ha0090000;
      case(aw[7:0])
        0:capctrl[e]<=wd;
        'h48:addr_lo[e]<=wd;
        'h4c:addr_hi[e]<=wd;
        'h58:begin
          if({addr_hi[e],addr_lo[e]} != 64'h1000000040 + (e ? 64'h80000000 : 0) + next_offset[e])
            $fatal(1,"Wrong stereo DMA address");
          next_offset[e]+=wd+128;
          length[e]<=wd;done[e]<=0;
        end
      endcase
    end
    if(rv) begin
      e=ar>=32'ha0090000;
      case(ar[7:0])
        'h08:rdata<=capstatus[e];
        'h30:rdata<=0;
        // Hold first ROI's DMA completion until the next exposure has ended.
        'h34:rdata<=done[e] && (!TRACE_TRANSITIONS || tick>=dma_visible[e]) && (TRACE_TRANSITIONS || received[e]!=2 ||
          (n>=3 && tick>falls[2]+(LATE_SOF_FAULT?FOT+100:5) && falls[2]>0)) ? 'h1002:0;
        'h58:rdata<=length[e];
        default:$fatal(1,"unexpected read");
      endcase
    end
  end
  task cmd(input [2:0] op,input integer arg);
    @(negedge clk);ctrl={~ctrl[31],op,arg[19:0],8'b0};
  endtask
  initial begin
    for(integer i=0;i<2;i++) begin next_offset[i]=0;beats[i]=0;received[i]=0;capctrl[i]=0;length[i]=0;end
    for(integer i=0;i<FRAME_COUNT;i++) falls[i]=0;
    repeat(5) @(negedge clk);resetn=1;repeat(5) @(negedge clk);
    cmd(1,R);cmd(4,EXP);cmd(2,0);
    if(WINDOW_FAULT) begin
      wait(!dut.running && dut.error!=0);
      if(dut.error!=14 || dut.lut_valid[WINDOW_FAULT==2 ? 1 : R+1] ||
         falls[n-1]-rises[n-1]!=EXP*RATE)
        $fatal(1,"Invalid window accepted or exposure stretched");
      $display("PASS missed window rejected");$finish;
    end else if(LONG_READOUT) begin
      wait(dut.error!=0);if(dut.error!=13 || dut.lut_valid[2]) $fatal(1,"Readout overrun not rejected");
      $display("PASS previous readout still active at exposure end");$finish;
    end else if(LATE_SOF_FAULT) begin
      wait(dut.error!=0); if(dut.error!=12 || dut.lut_valid[2]) $fatal(1,"Missed SOF not rejected");
      $display("PASS missed SOF rejected");$finish;
    end else begin
      wait(n==FRAME_COUNT);cmd(3,0);wait(!dut.running);
      if(dut.error || dut.completed!=FRAME_COUNT || (EXP==3600 && !FOT_BLOCKS_TICK && (!overlaps || !tp_gaps))) $fatal(1,"capture failed");
      for(integer i=0;i<n;i++) begin
        if(!dut.lut_valid[i] || dut.frame_ids[i]!=i || dut.frame_ticks[i]!=slots[i] ||
          dut.frame_rise[i]!=stamp[i] || dut.frame_fall[i]-stamp[i]!=EXP*RATE ||
          dut.frame_lengths[i]!=2*WIDTH*(i%(R+1)==0?3072:1024) || dut.frame_rois[i]!=(i%(R+1)!=0)) $fatal(1,"LUT mismatch");
        $display("frame %0d slot %0d width %0d cycles",i,slots[i],falls[i]-rises[i]);
      end
      if(!TRACE_TRANSITIONS && EXP==1000 && (slots[0]!=1 || slots[1]!=3 || slots[2]!=4 ||
         slots[3]!=5 || slots[4]!=6 || slots[5]!=8)) $fatal(1,"Mixed cadence");
      if(slots[2]-slots[1]!=(FOT_BLOCKS_TICK?2:1)) $fatal(1,"unexpected FOT gating");
      begin : check_trace
        integer count, pulses, confirmations_a, confirmations_b;
        reg [31:0] event_time, event_data;
        pulses=0;confirmations_a=0;confirmations_b=0;
        if(dut.line_count[0]!=3072 || dut.line_count[1]!=3072 ||
           dut.line_period[0]!=GROUPS+ROW_GAP || dut.line_period[1]!=GROUPS+ROW_GAP)
          $fatal(1,"FULL line telemetry mismatch");
        if(group_count>roi_groups && (dut.switch_rows[0]!=3072 || dut.switch_rows[1]!=3072))
          $fatal(1,"ROI-to-FULL line telemetry mismatch");
        if(group_count>roi_groups) $display("First overlapping FULL: A=%0d B=%0d rows, first FULL line period=%0.3f us",
                                 dut.switch_rows[0],dut.switch_rows[1],dut.line_period[0]*1.0/RATE);
        ctrl[7:0]=8'h30; #1;
        if(dut.status!==32'h54524331) $fatal(1,"Trace signature");
        ctrl[7:0]=8'h31; #1; count=dut.status;
        if(count<=0 || count>256) $fatal(1,"Trace missing or truncated");
        for(integer j=0;j<count;j++) begin
          ctrl[15:8]=j;ctrl[7:0]=8'h32;@(posedge clk);@(negedge clk);
          event_time=dut.status;ctrl[7:0]=8'h33; #1;event_data=dut.status;
          if(event_data[1]) begin
            if(!event_data[2] || event_time!==stamp[pulses][31:0] ||
               event_data[31:24]!=slots[pulses]) $fatal(1,"Trace TEXP mismatch");
            pulses++;
          end
          confirmations_a+=event_data[5];confirmations_b+=event_data[6];
        end
        if(pulses!=n || confirmations_a!=n || confirmations_b!=n) $fatal(1,"Trace event count");
      end
      $display("PASS overlap=%0d TP gaps=%0d frames=%0d",overlaps,tp_gaps,n);$finish;
    end
  end
  initial begin repeat((120000+R*8000)*RATE) @(posedge clk);$fatal(1,"Timeout state=%d error=%d frames=%d cap=%h DMA=%h",dut.state,dut.error,n,dut.last_cap,dut.last_dma);end
endmodule
