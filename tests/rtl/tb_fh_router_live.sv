`timescale 1ns/1ps
module tb_fh_router_live;
    localparam WIDTH=4096, HEIGHT=3072, LANES=16;
    reg clk=0, resetn=0, fval=0, lval=0, enable=0;
    always #4 clk=~clk;
    reg [191:0] pixels=0;
    reg [15:0] x0,y0,x1,y1;
    reg [2:0] logstep;
    wire [191:0] result;
    wire [15:0] keep;
    wire sof,eol,eof,done,fault;
    fh_router_live dut(clk,resetn,fval,lval,pixels,enable,x0,y0,x1,y1,logstep,
                       result,keep,sof,eol,eof,done,fault);
    task automatic run_frame(input integer left,top,right,bottom,shift,rows,
                             input bit armed,expect_error);
        integer x,y,i,col,step,count,lastx,lasty;
        reg [15:0] expected;
        reg first_group,last_group;
        begin
            x0=left; y0=top; x1=right; y1=bottom; logstep=shift; enable=armed;
            step=1<<shift; count=0;
            lastx=left+((right-left-1)/step)*step;
            lasty=top+((bottom-top-1)/step)*step;
            for(y=0;y<rows;y++) begin
                for(x=0;x<WIDTH;x+=LANES) begin
                    fval=1; lval=1; expected=0;
                    for(i=0;i<LANES;i++) begin
                        col=x+i;
                        pixels[i*12+:12]=(col+17*y)&1023;
                        expected[i]=armed && shift<=4 && col>=left && col<right &&
                            y>=top && y<bottom && (col-left)%step==0 && (y-top)%step==0;
                        if(expected[i]) count++;
                    end
                    @(negedge clk);
                    first_group=(|expected) && left>=x && left<x+LANES && y==top;
                    last_group=(|expected) && lastx>=x && lastx<x+LANES;
                    if(keep!==expected || (|expected && result!==pixels) || sof!==first_group ||
                       eol!==last_group || eof!==(last_group && y==lasty))
                        $fatal(1,"live mismatch at x=%0d y=%0d",x,y);
                    // Reprogram while streaming; current frame must keep its settings.
                    x0=1; logstep=4; enable=!armed;
                end
                if(y+1<rows) begin
                    lval=0; @(negedge clk);
                    if(keep!==0) $fatal(1,"blanking emitted pixels");
                end
            end
            fval=0; lval=0; @(negedge clk);
            if(done!==armed || fault!==expect_error || keep!==0)
                $fatal(1,"completion done=%b error=%b",done,fault);
            $display("LIVE_CASE_PASS rows=%0d step=%0d emitted=%0d error=%b",rows,step,count,fault);
        end
    endtask
    initial begin
        repeat(3) @(negedge clk); resetn=1;
        run_frame(0,0,4096,3072,2,3072,1,0);
        run_frame(13,5,1037,773,0,3072,1,0);
        run_frame(4081,3061,4096,3072,1,3072,1,0);
        run_frame(3,0,53,2,3,2,1,1); // truncated frame
        run_frame(0,0,32,2,5,2,1,1); // rejected step
        run_frame(0,0,32,2,0,2,0,0); // unselected trigger
        $display("FH_ROUTER_LIVE_PASS"); $finish;
    end
endmodule
