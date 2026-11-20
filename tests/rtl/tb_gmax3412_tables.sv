`timescale 1ns/1ps
module tb_gmax3412_tables;
 reg clk=0;always #4 clk=~clk;
 reg resetn=0,init_cmd=0,start_cmd=0,stop_cmd=0,trigger_cmd=0,wr=0,consume=1;
 reg [7:0] addr=0,raddr=0;reg [31:0] wdata=0;
 wire [31:0] rdata,accepted,rejected,skipped,fault,checked,check_errors,last_pixels,last_lines,checksum;
 wire write_ok,enabled,armed,exposing,flash,read_busy,pending,fval,lval,last_pass,active_roi;
 wire readout_cmd=consume && pending && !read_busy;
 wire [191:0] pixels;wire [9:0] active_seed;wire [7:0] analog_gain;wire [15:0] digital_gain;
 gmax3412_sequence #(.WIDTH(16),.HEIGHT(2),.ROI_HEIGHT(1),.ROI_START(1024)) dut(.*,.blank_cycles(32'd1));
 task put(input [7:0] a,input [31:0] d);
 begin @(negedge clk);addr=a;wdata=d;wr=1;@(negedge clk);wr=0;end
 endtask
 task pulse;
 begin @(negedge clk);trigger_cmd=1;@(negedge clk);trigger_cmd=0;end
 endtask
 initial begin
  repeat(4)@(negedge clk);resetn=1;
  put('h70,1);
  for(integer n=0;n<256;n++)begin
   put('h74,n);put('h78,n==255?7:3);
   put('h7c,(n&1)|(n<<1)|((n*257)<<9));put('h80,n&1);
  end
  put('h84,0);raddr='h84;#1;if(rdata!=0)$fatal(1,"256-entry length encoding");
  @(negedge clk);start_cmd=1;@(negedge clk);start_cmd=0;
  for(integer n=0;n<258;n++)begin
   pulse();
   if(analog_gain!=(n&255)||digital_gain!=((n&255)*257)||flash!=(n&1))$fatal(1,"Capture LUT wrap/snapshot %d",n);
   if(dut.exposure_timer!=((n&255)==255?7:3))$fatal(1,"Exposure LUT width/index");
   repeat(100)@(negedge clk);
   if(active_roi!=(n&1))$fatal(1,"Readout LUT wrap %d",n);
   raddr='ha0;#1;
   if(rdata!=((n&1)|((n&255)<<1)|(((n&255)*257)<<9)))$fatal(1,"Readout parameter association");
  end
  if(checked!=258||check_errors||fault||skipped||accepted!=258)$fatal(1,"Table run counters");
  // FV must not wait indefinitely for receiver preparation.
  consume=0;pulse();repeat(100)@(negedge clk);
  if(fault!=3 || armed)$fatal(1,"Unprepared autonomous FV not reported");
  @(negedge clk);stop_cmd=1;@(negedge clk);stop_cmd=0;
  if(pending||read_busy||exposing||flash)$fatal(1,"Abort did not release source");
  $display("TABLES_PASS: all 256 capture/readout entries, zero length encoding, wrap, exposure/flash/8-bit PGA/16-bit digital snapshots, overflow and abort");
  $finish;
 end
 initial begin #1000000;$fatal(1,"Watchdog");end
endmodule
