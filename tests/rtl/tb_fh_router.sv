`timescale 1ns/1ps
module tb_fh_router;
    reg clk=0, resetn=0;
    always #5 clk=~clk;
    reg [5:0] awaddr=0;
    reg awvalid=0, wvalid=0;
    wire awready,wready,bvalid;
    wire [1:0] bresp;
    reg [31:0] wdata=0;
    reg [15:0] din=0;
    reg valid=0,last=0,ready=0;
    wire inready,outvalid,outlast;
    wire [15:0] dout;
    wire [1:0] keep;
    integer seen=0, cycle=0, nx,ny,bx,ex,ey,st,total,seed,case_id=0;
    reg checking=0, held=0;
    reg [16:0] previous;
    fh_router dut(.clk(clk),.resetn(resetn),
        .s_axi_awprot(3'b0),.s_axi_arprot(3'b0),
        .s_axi_awaddr(awaddr),.s_axi_awvalid(awvalid),.s_axi_awready(awready),
        .s_axi_wdata(wdata),.s_axi_wstrb(4'hf),.s_axi_wvalid(wvalid),.s_axi_wready(wready),
        .s_axi_bresp(bresp),.s_axi_bvalid(bvalid),.s_axi_bready(1'b1),
        .s_axi_araddr(6'b0),.s_axi_arvalid(1'b0),.s_axi_arready(),
        .s_axi_rdata(),.s_axi_rresp(),.s_axi_rvalid(),.s_axi_rready(1'b1),
        .s_axis_tdata(din),.s_axis_tkeep(2'b11),.s_axis_tvalid(valid),.s_axis_tlast(last),.s_axis_tready(inready),
        .m_axis_tdata(dout),.m_axis_tkeep(keep),.m_axis_tvalid(outvalid),.m_axis_tlast(outlast),.m_axis_tready(ready));
    function automatic [15:0] pixel(input integer x,y,s);
        pixel=(x+17*y+s)&1023;
    endfunction
    always @(negedge clk) begin cycle=cycle+1; ready=(cycle%7!=0 && cycle%7!=1); end
    always @(posedge clk) if(resetn) begin
        if(held && (!outvalid || {outlast,dout}!==previous)) $fatal(1,"Output changed under backpressure");
        held=outvalid&&!ready; previous={outlast,dout};
        if(checking && outvalid && ready) begin
            if(seen>=total || ny>=ey) $fatal(1,"Case %0d: extra output after rectangle end, seen=%0d expected=%0d y=%0d y1=%0d",case_id,seen,total,ny,ey);
            if(dout!==pixel(nx,ny,seed) || keep!==2'b11 || outlast!==(seen==total-1))
                $fatal(1,"Pixel/framing mismatch at output %0d (%0d,%0d)",seen,nx,ny);
            seen=seen+1;
            if(nx+st>=ex) begin nx=bx; ny=ny+st; end else nx=nx+st;
        end
    end
    task automatic write_reg(input [5:0] a,input [31:0] d);
        // Deliberately separate address and data handshakes.
        @(negedge clk); awaddr=a; awvalid=1;
        do @(posedge clk); while(!awready);
        @(negedge clk); awvalid=0;
        repeat(2) @(negedge clk);
        wdata=d; wvalid=1;
        do @(posedge clk); while(!wready);
        @(negedge clk); wvalid=0;
        wait(bvalid); if(bresp!=0) $fatal(1,"AXI write rejected");
        @(negedge clk);
    endtask
    task automatic run_case(input integer h, x0,y0,x1,y1,step,s);
        integer x,y;
        case_id=case_id+1;
        $display("ROUTER_CASE %0d: source=4096x%0d rectangle=(%0d,%0d)-(%0d,%0d) step=%0d",case_id,h,x0,y0,x1,y1,step);
        write_reg(4,2); write_reg(8,h); write_reg(12,x0); write_reg(16,y0);
        write_reg(20,x1); write_reg(24,y1); write_reg(28,step);
        total=((x1-x0+step-1)/step)*((y1-y0+step-1)/step);
        write_reg(32,total);
        nx=x0; ny=y0; bx=x0; ex=x1; ey=y1; st=step; seed=s; seen=0; checking=1;
        write_reg(4,1);
        for(y=0;y<h;y=y+1) for(x=0;x<4096;x=x+1) begin
            @(negedge clk); din=pixel(x,y,s); valid=1; last=(x==4095 && y==h-1);
            do @(posedge clk); while(!inready);
        end
        @(negedge clk); valid=0; last=0;
        wait(!outvalid); repeat(3) @(negedge clk);
        if(seen!=total || !dut.done || dut.fault || dut.remaining!=0 || dut.emitted!=total)
            $fatal(1,"Case %0d completion mismatch: seen=%0d expected=%0d emitted=%0d remaining=%0d done=%b fault=%b",case_id,seen,total,dut.emitted,dut.remaining,dut.done,dut.fault);
        $display("ROUTER_CASE_PASS %0d: %0d pixels",case_id,seen);
        checking=0;
    endtask
    initial begin
        repeat(4) @(negedge clk); resetn=1;
        run_case(4,13,1,16,3,1,0); // unaligned rectangle, discarded tail
        run_case(8,13,1,16,2,1,0); // one selected row, six trailing rows must be discarded
        run_case(8,0,0,16,3,2,5); // strided selection ends before source bottom
        run_case(4,4095,3,4096,4,1,9); // final source pixel, partial memory beat
        run_case(4,0,0,4096,4,1,3); // pass all pixels
        run_case(3072,0,0,4096,3072,16,0); // production full frame
        run_case(1024,13,17,16,19,1,7); // stored ROI sensor 1
        run_case(3072,13,1041,16,1043,1,7); // matching band in FULL
        $display("FH_ROUTER_PASS"); $finish;
    end
    initial begin #1000000000; $fatal(1,"watchdog timeout"); end
endmodule
