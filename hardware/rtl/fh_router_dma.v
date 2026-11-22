// Export-only pixel selector. One uint16 pixel per AXIS beat.
// Register offsets: 00 signature, 04 control/status, 08 height,
// 0c x0, 10 y0, 14 x1, 18 y1, 1c step, 20 output count.
// Bounds are source-local, end exclusive; input width is always 4096.
module fh_router_dma (
    (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF s_axi:s_axis:m_axis, ASSOCIATED_RESET resetn" *)
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 clk CLK" *)
    input wire clk,
    (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *) (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 resetn RST" *)
    input wire resetn,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi AWPROT" *)
    input wire [2:0] s_axi_awprot,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi ARPROT" *)
    input wire [2:0] s_axi_arprot,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi AWADDR" *)
    (* X_INTERFACE_PARAMETER = "PROTOCOL AXI4LITE, DATA_WIDTH 32, ADDR_WIDTH 6" *)
    input wire [5:0] s_axi_awaddr, (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi AWVALID" *)
    input wire s_axi_awvalid, (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi AWREADY" *)
    output wire s_axi_awready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi WDATA" *)
    input wire [31:0] s_axi_wdata, (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi WSTRB" *)
    input wire [3:0] s_axi_wstrb,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi WVALID" *)
    input wire s_axi_wvalid, (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi WREADY" *)
    output wire s_axi_wready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi BRESP" *)
    output reg [1:0] s_axi_bresp, (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi BVALID" *)
    output reg s_axi_bvalid, (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi BREADY" *)
    input wire s_axi_bready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi ARADDR" *)
    input wire [5:0] s_axi_araddr, (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi ARVALID" *)
    input wire s_axi_arvalid, (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi ARREADY" *)
    output wire s_axi_arready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi RDATA" *)
    output reg [31:0] s_axi_rdata, (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi RRESP" *)
    output reg [1:0] s_axi_rresp,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi RVALID" *)
    output reg s_axi_rvalid, (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi RREADY" *)
    input wire s_axi_rready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis TDATA" *)
    input wire [15:0] s_axis_tdata, (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis TKEEP" *)
    input wire [1:0] s_axis_tkeep,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis TLAST" *)
    input wire s_axis_tlast, (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis TVALID" *)
    input wire s_axis_tvalid, (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis TREADY" *)
    output wire s_axis_tready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis TDATA" *)
    output reg [15:0] m_axis_tdata, (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis TKEEP" *)
    output wire [1:0] m_axis_tkeep,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis TLAST" *)
    output reg m_axis_tlast, (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis TVALID" *)
    output reg m_axis_tvalid, (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis TREADY" *)
    input wire m_axis_tready
);
    reg aw_pending, w_pending;
    reg [5:0] awaddr;
    reg [31:0] wdata;
    reg [3:0] wstrb;
    reg [31:0] cfg [0:6];
    reg [31:0] height, x0, y0, x1, y1, step, remaining;
    reg [31:0] x, y, next_x, next_y, emitted;
    reg busy, done, fault;
    // The next coordinate keeps advancing after the last selected row. Stop at
    // the exclusive rectangle boundary while draining the rest of the source.
    wire selected = x == next_x && y == next_y && x < x1 && y < y1;
    wire slot_free = !m_axis_tvalid || m_axis_tready;
    assign s_axis_tready = busy && (!selected || slot_free);
    assign m_axis_tkeep = 2'b11;
    assign s_axi_awready = !aw_pending && !s_axi_bvalid;
    assign s_axi_wready = !w_pending && !s_axi_bvalid;
    assign s_axi_arready = !s_axi_rvalid;
    integer i, b;
    always @(posedge clk) begin
        if (!resetn) begin
            aw_pending<=0; w_pending<=0; s_axi_bvalid<=0; s_axi_bresp<=0;
            s_axi_rvalid<=0; s_axi_rresp<=0; s_axi_rdata<=0;
            busy<=0; done<=0; fault<=0; emitted<=0;
            m_axis_tvalid<=0; m_axis_tlast<=0; m_axis_tdata<=0;
            x<=0; y<=0; next_x<=0; next_y<=0; remaining<=0;
            height<=0; x0<=0; y0<=0; x1<=0; y1<=0; step<=1;
            for(i=0;i<7;i=i+1) cfg[i]<=0;
        end else begin
            if (s_axi_bvalid && s_axi_bready) s_axi_bvalid<=0;
            if (s_axi_rvalid && s_axi_rready) s_axi_rvalid<=0;
            if (s_axi_awvalid && s_axi_awready) begin awaddr<=s_axi_awaddr; aw_pending<=1; end
            if (s_axi_wvalid && s_axi_wready) begin wdata<=s_axi_wdata; wstrb<=s_axi_wstrb; w_pending<=1; end
            if (m_axis_tvalid && m_axis_tready) m_axis_tvalid<=0;
            if (s_axi_arvalid && s_axi_arready) begin
                s_axi_rvalid<=1; s_axi_rresp<=0;
                case(s_axi_araddr[5:2])
                    0: s_axi_rdata<=32'h46525231;
                    1: s_axi_rdata<={29'b0,fault,done,busy};
                    8: s_axi_rdata<=emitted;
                    default: begin
                        if (s_axi_araddr[5:2]>=2 && s_axi_araddr[5:2]<=7)
                            s_axi_rdata<=cfg[s_axi_araddr[5:2]-2];
                        else s_axi_rdata<=0;
                    end
                endcase
            end
            if (busy && s_axis_tvalid && s_axis_tready) begin
                if (s_axis_tkeep != 2'b11 || s_axis_tlast != (x==4095 && y==height-1)) fault<=1;
                if (selected) begin
                    m_axis_tdata<=s_axis_tdata; m_axis_tvalid<=1;
                    m_axis_tlast<=remaining==1;
                    remaining<=remaining-1; emitted<=emitted+1;
                    if (next_x+step>=x1) begin next_x<=x0; next_y<=next_y+step; end
                    else next_x<=next_x+step;
                end
                if (x==4095) begin
                    x<=0;
                    if (y==height-1) begin
                        busy<=0; done<=1;
                        if (remaining != (selected ? 1 : 0)) fault<=1;
                    end
                    else y<=y+1;
                end else x<=x+1;
            end
            // Software abort has priority over data; DMA must also be reset.
            if (aw_pending && w_pending && !s_axi_bvalid) begin
                aw_pending<=0; w_pending<=0; s_axi_bvalid<=1; s_axi_bresp<=0;
                if (awaddr[5:2]==1 && wstrb[0]) begin
                    if (wdata[1]) begin busy<=0; done<=0; fault<=0; m_axis_tvalid<=0; end
                    else if (wdata[0]) begin
                        if (busy || m_axis_tvalid || cfg[0]==0 || cfg[0]>3072 ||
                            cfg[1]>=cfg[3] || cfg[3]>4096 || cfg[2]>=cfg[4] || cfg[4]>cfg[0] ||
                            cfg[5]==0 || cfg[5]>16 || cfg[6]==0) begin
                            fault<=1; s_axi_bresp<=2;
                        end else begin
                            height<=cfg[0]; x0<=cfg[1]; y0<=cfg[2]; x1<=cfg[3]; y1<=cfg[4]; step<=cfg[5];
                            remaining<=cfg[6]; x<=0; y<=0; next_x<=cfg[1]; next_y<=cfg[2];
                            emitted<=0; busy<=1; done<=0; fault<=0;
                        end
                    end
                end else if (awaddr[5:2]>=2 && awaddr[5:2]<=8 && !busy) begin
                    for(b=0;b<4;b=b+1) if(wstrb[b]) cfg[awaddr[5:2]-2][b*8+:8]<=wdata[b*8+:8];
                end else s_axi_bresp<=2;
            end
        end
    end
endmodule
