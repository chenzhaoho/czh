// Host-controlled live RTL harness, not an alternative FIFO implementation.
// Python supplies pending words; only actual DUT write/read handshakes deliver them.
`timescale 1ns/1ps
module tb_terminal_live;
    parameter integer SYNC_STAGES=2;
    localparam integer HOST_CAP=16384, BATCH_CAP=4096;
    reg clk_a=0, clk_b=0, rst_n=0;
    reg receive_a=1, receive_b=1;
    reg av=0,bv=0,ar=0,br=0;
    reg [31:0] ad=0,bd=0;
    wire at,bt,ax,bx,af,bf;
    wire [31:0] aq,bq;
    wire [8:0] atu,btu,aru,bru;
    reg [31:0] host_a[0:HOST_CAP-1],host_b[0:HOST_CAP-1];
    reg [31:0] batch_a[0:BATCH_CAP-1],batch_b[0:BATCH_CAP-1];
    integer load_a=0,load_b=0,count_a=0,count_b=0;
    integer seen_a=0,seen_b=0,tail_a=0,tail_b=0,head_a=0,head_b=0;
    integer tx_a=0,tx_b=0,rx_a=0,rx_b=0,stalls_a=0,stalls_b=0;
    integer errors=0,events,i_a,i_b;
    reg held_av=0,held_bv=0,held_ax=0,held_bx=0;
    reg [31:0] last_ad,last_bd,last_aq,last_bq;
    wire [31:0] pending_a=tail_a-head_a,pending_b=tail_b-head_b;
    always #5 clk_a=~clk_a;
    initial begin #1.701; forever #7 clk_b=~clk_b; end
    dual_fifo_link #(.SYNC_STAGES(SYNC_STAGES)) dut (
        .clk_a(clk_a),.clk_b(clk_b),.rst_n_async(rst_n),
        .a_tx_valid(av),.a_tx_ready(at),.a_tx_data(ad),.a_rx_valid(ax),.a_rx_ready(ar),.a_rx_data(aq),
        .b_tx_valid(bv),.b_tx_ready(bt),.b_tx_data(bd),.b_rx_valid(bx),.b_rx_ready(br),.b_rx_data(bq),
        .a_tx_full(af),.b_tx_full(bf),.a_tx_used(atu),.b_tx_used(btu),.a_rx_used(aru),.b_rx_used(bru)
    );
    initial begin
        events=$fopen("handshakes.csv","w");
        if(!events) $fatal(1,"Cannot open live handshake record");
        $fdisplay(events,"time_ps,direction,event,data,wr_bin,rd_bin,wr_gray,rd_gray");
        $fflush(events);
        $dumpfile("terminal_live.vcd");
        $dumpvars(0,clk_a,clk_b,rst_n,receive_a,receive_b,av,bv,ar,br,at,bt,ax,bx,ad,bd,aq,bq,af,bf,atu,btu,
                  dut.u_ab.wr_bin,dut.u_ab.rd_bin,dut.u_ab.wr_gray,dut.u_ab.rd_gray,
                  dut.u_ba.wr_bin,dut.u_ba.rd_bin,dut.u_ba.wr_gray,dut.u_ba.rd_gray,
                  dut.u_ab.wr_gray_sync,dut.u_ab.rd_gray_sync,dut.u_ba.wr_gray_sync,dut.u_ba.rd_gray_sync);
    end
    always @(negedge clk_a) begin
        if(!rst_n) begin av=0;ad=0;ar=0;tail_a=0;seen_a=load_a;end
        else begin
            if(load_a!=seen_a) begin
                if(count_a<1 || count_a>BATCH_CAP || tail_a-head_a+count_a>HOST_CAP)
                    $fatal(1,"Host A staging capacity exceeded");
                $readmemh("input_a.hex",batch_a,0,count_a-1);
                for(i_a=0;i_a<count_a;i_a=i_a+1) host_a[(tail_a+i_a)%HOST_CAP]=batch_a[i_a];
                tail_a=tail_a+count_a;seen_a=load_a;
            end
            av=head_a<tail_a;ad=av?host_a[head_a%HOST_CAP]:32'd0;ar=receive_a;
        end
    end
    always @(negedge clk_b) begin
        if(!rst_n) begin bv=0;bd=0;br=0;tail_b=0;seen_b=load_b;end
        else begin
            if(load_b!=seen_b) begin
                if(count_b<1 || count_b>BATCH_CAP || tail_b-head_b+count_b>HOST_CAP)
                    $fatal(1,"Host B staging capacity exceeded");
                $readmemh("input_b.hex",batch_b,0,count_b-1);
                for(i_b=0;i_b<count_b;i_b=i_b+1) host_b[(tail_b+i_b)%HOST_CAP]=batch_b[i_b];
                tail_b=tail_b+count_b;seen_b=load_b;
            end
            bv=head_b<tail_b;bd=bv?host_b[head_b%HOST_CAP]:32'd0;br=receive_b;
        end
    end
    always @(posedge clk_a or negedge rst_n) begin
        if(!rst_n) begin head_a=0;tx_a=0;rx_a=0;stalls_a=0;held_av=0;held_ax=0;end
        else begin
            if(held_av && !(av && ad===last_ad)) begin errors=errors+1;$display("[FAIL] A source hold");end
            if(held_ax && !(ax && aq===last_aq)) begin errors=errors+1;$display("[FAIL] A read hold");end
            held_av=av&&!at;last_ad=ad;held_ax=ax&&!ar;last_aq=aq;
            if(av&&!at) stalls_a=stalls_a+1;
            if(av&&at) begin
                head_a=head_a+1;tx_a=tx_a+1;
                $fdisplay(events,"%0t,AB,W,%08h,%0d,%0d,%0d,%0d",$realtime,ad,dut.u_ab.wr_bin,dut.u_ab.rd_bin,dut.u_ab.wr_gray,dut.u_ab.rd_gray);
            end
            if(ax&&ar) begin
                rx_a=rx_a+1;
                $fdisplay(events,"%0t,BA,R,%08h,%0d,%0d,%0d,%0d",$realtime,aq,dut.u_ba.wr_bin,dut.u_ba.rd_bin,dut.u_ba.wr_gray,dut.u_ba.rd_gray);
            end
            $fflush(events);
        end
    end
    always @(posedge clk_b or negedge rst_n) begin
        if(!rst_n) begin head_b=0;tx_b=0;rx_b=0;stalls_b=0;held_bv=0;held_bx=0;end
        else begin
            if(held_bv && !(bv && bd===last_bd)) begin errors=errors+1;$display("[FAIL] B source hold");end
            if(held_bx && !(bx && bq===last_bq)) begin errors=errors+1;$display("[FAIL] B read hold");end
            held_bv=bv&&!bt;last_bd=bd;held_bx=bx&&!br;last_bq=bq;
            if(bv&&!bt) stalls_b=stalls_b+1;
            if(bv&&bt) begin
                head_b=head_b+1;tx_b=tx_b+1;
                $fdisplay(events,"%0t,BA,W,%08h,%0d,%0d,%0d,%0d",$realtime,bd,dut.u_ba.wr_bin,dut.u_ba.rd_bin,dut.u_ba.wr_gray,dut.u_ba.rd_gray);
            end
            if(bx&&br) begin
                rx_b=rx_b+1;
                $fdisplay(events,"%0t,AB,R,%08h,%0d,%0d,%0d,%0d",$realtime,bq,dut.u_ab.wr_bin,dut.u_ab.rd_bin,dut.u_ab.wr_gray,dut.u_ab.rd_gray);
            end
            $fflush(events);
        end
    end
endmodule
