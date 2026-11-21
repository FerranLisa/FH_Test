`timescale 1ns/1ps
module tb_gmax_texp;
  reg clk=0, resetn=0;
  always #4 clk=~clk;
  reg [31:0] control=0;
  wire [3:0] drive;
  gmax3412_dual_ring dut(.clk(clk), .resetn(resetn), .calib_ready(1'b1),
    .control(control), .texp_drive(drive), .texp_pins(drive[1:0]), .rtc_seconds_irq(1'b0));

  task pulse(input [3:0] mask, input [19:0] duration);
    reg [3:0] expected;
    begin
      expected=mask==0 ? 4'b0011 : mask;
      control={~control[31],3'b000,duration,mask,4'b0000};
      repeat(duration*120) begin
        @(negedge clk);
        if (drive!==expected) $fatal(1,"Wrong output mask or pulse duration");
        control[7:0]=15; // Firmware polls status while the pulse is active.
      end
      @(negedge clk);
      if (drive!==0) $fatal(1,"Pulse failed to end");
    end
  endtask
  initial begin
    repeat(4) @(negedge clk);
    resetn=1;
    repeat(4) @(negedge clk);
    pulse(1,1000); pulse(2,1); pulse(3,1000);
    pulse(4,100); pulse(8,100); pulse(0,3);
    $display("PASS FPGA TEXP masks and widths");
    $finish;
  end
endmodule
