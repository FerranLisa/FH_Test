`timescale 1ns/1ps
// Production geometry and 120 MHz cycle counts; no reduced-width timing shortcut.
module tb_gmax3412_sensor_timing;
 reg clk=0;always #4.166667 clk=~clk;
 reg resetn=0,init_cmd=0,start_cmd=0,stop_cmd=0,trigger_cmd=0,wr=0;
 reg [7:0] addr=0,raddr=0;reg [31:0] wdata=0;
 wire [31:0] rdata,accepted,rejected,skipped,fault,checked,check_errors,last_pixels,last_lines,checksum;
 wire write_ok,enabled,armed,exposing,flash,read_busy,pending,fval,lval,last_pass,active_roi;
 wire readout_cmd=pending; // Receiver ready in advance; never controls source FV timing.
 wire [191:0] pixels;wire [9:0] active_seed;wire [7:0] analog_gain;wire [15:0] digital_gain;
 gmax3412_sequence dut(.*,.blank_cycles(32'd1));
 integer cycle=0,last_start=-1,fv_start=0,frames=0,exp_width=0;
 reg old_fv=0;
 always @(posedge clk) begin
  cycle++;
  old_fv<=fval;
  if(exposing)exp_width++;
  else if(exp_width!=0) begin
   if(exp_width!=120000)$fatal(1,"Exposure duration changed");
   exp_width=0;
  end
  if(exposing && read_busy)$fatal(1,"Exposure overlaps readout");
  if(trigger_cmd)begin
   if(last_start>=0 && cycle-last_start!=480000)$fatal(1,"4ms timer spacing");
   last_start=cycle;
  end
  if(fval && !old_fv)fv_start=cycle;
  if(!fval && old_fv)begin
   if(cycle-fv_start!=(frames==0?789504:263168))$fatal(1,"Production readout cycles %d",cycle-fv_start);
   frames++;
  end
 end
 task put(input [7:0] a,input [31:0] d);
 begin @(negedge clk);addr=a;wdata=d;wr=1;@(negedge clk);wr=0;end
 endtask
 initial begin
  repeat(5)@(negedge clk);resetn=1;
  put('h70,1);
  @(negedge clk);start_cmd=1;@(negedge clk);start_cmd=0;
  // Exercise upper bits and 32-bit rollover without simulating millions of slots.
  dut.slot_id=32'hFFFFFFFE;
  for(integer n=0;n<5;n++)begin
   trigger_cmd=1;@(negedge clk);trigger_cmd=0;
   raddr=8'hb8;#1;
   if(rdata!=(n<2?32'hFFFFFFFF:n-1))$fatal(1,"Timer pulse latch/wrap/skip");
   repeat(479999)@(negedge clk);
  end
  wait(checked==4);repeat(8)@(negedge clk);
  if(accepted!=4 || skipped!=1 || fault || check_errors || dut.extended_frames!=0 || dut.extension_cycles!=0)
   $fatal(1,"Sensor timing counts accepted=%d skipped=%d fault=%d extended=%d",accepted,skipped,fault,dut.extended_frames);
  $display("SENSOR_TIMING_PASS: production 4096x3072/1024, 480000-cycle triggers, 120000-cycle TEXP, FOT, autonomous FV, 32-bit pulse latch/wrap, one discarded readout-busy tick, zero extension, no image queue");
  $finish;
 end
 initial begin #30000000;$fatal(1,"Sensor timing watchdog");end
endmodule
