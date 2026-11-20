`timescale 1ns/1ps
module tb_gmax3412_control;
    reg clk=0; always #4.166667 clk=~clk;
    reg resetn=0;
    reg [7:0] awaddr=0,araddr=0;
    reg awvalid=0,wvalid=0,bready=0,arvalid=0,rready=0;
    reg [31:0] wdata=0;
    reg [3:0] wstrb=15;
    wire awready,wready,bvalid,arready,rvalid;
    wire [1:0] bresp,rresp;
    wire [31:0] rdata;
    reg readout_in=0;
    reg init_in=0,start_in=0,stop_in=0,trigger_in=0;
    wire fval,lval,busy,initialized,armed,texp;
    wire [191:0] data;
    gmax3412_emulator #(.IMAGE_WIDTH(16),.IMAGE_HEIGHT(2)) dut (
        .s_axi_aclk(clk),.s_axi_aresetn(resetn),
        .s_axi_awaddr(awaddr),.s_axi_awprot(3'b0),.s_axi_awvalid(awvalid),.s_axi_awready(awready),
        .s_axi_wdata(wdata),.s_axi_wstrb(wstrb),.s_axi_wvalid(wvalid),.s_axi_wready(wready),
        .s_axi_bresp(bresp),.s_axi_bvalid(bvalid),.s_axi_bready(bready),
        .s_axi_araddr(araddr),.s_axi_arprot(3'b0),.s_axi_arvalid(arvalid),.s_axi_arready(arready),
        .s_axi_rdata(rdata),.s_axi_rresp(rresp),.s_axi_rvalid(rvalid),.s_axi_rready(rready),
        .init_in(init_in),.acquisition_start(start_in),.acquisition_stop(stop_in),.trigger_in(trigger_in),.readout_in(readout_in),
        .fvalout(fval),.lvalout(lval),.dataout(data),.busy(busy),.initialized(initialized),
        .armed(armed),.cmos_texp1(texp));
    task tick(input integer n); repeat(n) @(negedge clk); endtask
    // Deliberately separate AW/W in either order and stall the response.
    task wr(input [7:0] a,input [31:0] d,input bit data_first,input [3:0] strb,input [1:0] resp);
        begin
            if(data_first) begin
                @(negedge clk); wdata=d; wstrb=strb; wvalid=1;
                do @(posedge clk); while(!wready);
                @(negedge clk); wvalid=0; tick(3);
                awaddr=a; awvalid=1;
                do @(posedge clk); while(!awready);
                @(negedge clk); awvalid=0;
            end else begin
                @(negedge clk); awaddr=a; awvalid=1;
                do @(posedge clk); while(!awready);
                @(negedge clk); awvalid=0; tick(2);
                wdata=d; wstrb=strb; wvalid=1;
                do @(posedge clk); while(!wready);
                @(negedge clk); wvalid=0;
            end
            wait(bvalid); tick(3);
            if(!bvalid || bresp!==resp) $fatal(1,"Write response %h",a);
            bready=1; tick(1); bready=0;
        end
    endtask
    task rd(input [7:0] a,input [31:0] expected,input [1:0] resp);
        reg [31:0] held;
        begin
            @(negedge clk); araddr=a; arvalid=1;
            do @(posedge clk); while(!arready);
            @(negedge clk); arvalid=0;
            wait(rvalid); held=rdata; tick(3);
            if(!rvalid || rdata!==held || rresp!==resp || rdata!==expected)
                $fatal(1,"Read %h got %h expected %h response %h",a,rdata,expected,rresp);
            rready=1; tick(1); rready=0;
        end
    endtask
    localparam SETTINGS=(32'h1234<<9)|(32'h12<<1)|1;
    initial begin
      tick(4);resetn=1;tick(4);
      rd('h68,32'h44530030,0);
      wr('h70,1,0,15,0);wr('h74,0,1,15,0);
      wr('h78,100,0,15,0);wr('h7c,SETTINGS,1,15,0);wr('h80,0,0,15,0);
      rd('h78,100,0);rd('h7c,SETTINGS,0);
      wr('h78,7,1,1,2);rd('h78,100,0); // No torn word on partial AXI write.
      wr('h84,'h101,0,15,0);rd('h78,120000,0); // CPU now sees inactive bank.
      wr('h04,1,0,15,0);tick(40);wr('h04,2,1,15,0);
      @(negedge clk);trigger_in=1;@(negedge clk);trigger_in=0;
      wait(texp);wr('h84,'h101,0,15,2);wr('h70,0,1,15,2);
      wr('h78,7,0,15,0);
      wait(dut.seq_pending);@(negedge clk);readout_in=1;@(negedge clk);readout_in=0;
      wait(!busy);tick(5);
      rd('hb8,1,0);rd('h20,1,0);rd('h28,1,0);rd('ha0,SETTINGS,0);rd('ha4,100,0);rd('ha8,0,0);rd('hac,2,0);
      wr('h04,4,0,15,0);wr('h70,0,1,15,0);rd('h70,0,0);
      $display("CONTROL_AXI_PASS: split AW/W, table readback/bank swap, partial-write rejection, busy commit/mode rejection, frame parameter retention");$finish;
    end
    initial begin #1000000;$fatal(1,"Control watchdog enabled=%b armed=%b exposing=%b pending=%b reading=%b accepted=%d frames=%d fault=%d addr=%h",dut.seq_enabled,dut.seq_armed,dut.seq_exposing,dut.seq_pending,dut.seq_busy,dut.seq_accepted,dut.seq_frames,dut.seq_fault,awaddr);end
endmodule
