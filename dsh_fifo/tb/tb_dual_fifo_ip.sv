`timescale 1ns/1ps
// Black-box IP test. The scoreboard only observes ready/valid interface pins.
module tb_dual_fifo_ip #(
    parameter integer DW=32, AW=8, SYNC_STAGES=2, SWAP_CLOCKS=0
);
    localparam integer DEPTH=1<<AW, MAX_WORDS=8*DEPTH+256;
    reg [1:0] clk=0, tx_valid=0, rx_ready=0;
    reg rst_n=0, random_offers=0;
    reg [DW-1:0] tx_data[0:1];
    wire [DW-1:0] rx_data[0:1];
    wire [1:0] tx_ready, rx_valid, full;
    wire [AW:0] tx_used[0:1], rx_used[0:1];
    integer goal[0:1], mode[0:1], writes[0:1], reads[0:1], stalls[0:1];
    reg [DW-1:0] reference_words[0:1][0:MAX_WORDS-1];
    integer seed, epoch=0;
    reg [31:0] salt;

    always #(SWAP_CLOCKS ? 7 : 5) clk[0]=~clk[0];
    initial begin
        #1.701;
        forever #(SWAP_CLOCKS ? 5 : 7) clk[1]=~clk[1];
    end

    dual_fifo_link #(.DW(DW), .AW(AW), .SYNC_STAGES(SYNC_STAGES)) dut (
        .clk_a(clk[0]), .clk_b(clk[1]), .rst_n_async(rst_n),
        .a_tx_valid(tx_valid[0]), .a_tx_ready(tx_ready[0]), .a_tx_data(tx_data[0]),
        .b_tx_valid(tx_valid[1]), .b_tx_ready(tx_ready[1]), .b_tx_data(tx_data[1]),
        .a_rx_valid(rx_valid[0]), .a_rx_ready(rx_ready[0]), .a_rx_data(rx_data[0]),
        .b_rx_valid(rx_valid[1]), .b_rx_ready(rx_ready[1]), .b_rx_data(rx_data[1]),
        .a_tx_full(full[0]), .a_tx_used(tx_used[0]), .a_rx_used(rx_used[0]),
        .b_tx_full(full[1]), .b_tx_used(tx_used[1]), .b_rx_used(rx_used[1])
    );

    for (genvar i=0; i<2; i=i+1) begin : endpoint
        localparam integer PEER=1-i;
        reg accepted=0, held_rx=0, held_tx=0;
        reg [DW-1:0] prior_rx, prior_tx;
        reg [31:0] noise;

        always @(negedge clk[i]) begin
            if (!rst_n) begin
                tx_valid[i]=0;
                rx_ready[i]=0;
                tx_data[i]=0;
                noise=salt ^ (i ? 32'h91b43a77 : 32'h113fedc1);
                if (!noise) noise=1;
            end else begin
                noise={noise[30:0],noise[31]^noise[21]^noise[1]^noise[0]};
                rx_ready[i]=mode[i]==1 || (mode[i]==2 && (noise[1] || noise[12]));
                if (!tx_valid[i] || accepted) begin
                    tx_valid[i]=writes[i]<goal[i] && (!random_offers || noise[3] || noise[14]);
                    tx_data[i]=(writes[i]*32'h9e3779b1) ^ noise ^ (epoch*32'h13579bdf) ^ i;
                end
            end
        end

        always @(posedge clk[i]) begin
            if (!rst_n) begin
                writes[i]=0;
                reads[PEER]=0;
                stalls[i]=0;
                held_rx=0;
                held_tx=0;
                accepted=0;
            end else begin
                if ((^{tx_ready[i],rx_valid[i],full[i],tx_used[i],rx_used[i]}) === 1'bx)
                    $fatal(1,"unknown handshake or status at endpoint %0d",i);
                if (tx_used[i]>DEPTH || rx_used[i]>DEPTH || (full[i] != (tx_used[i]==DEPTH)))
                    $fatal(1,"bad local occupancy at endpoint %0d",i);
                if (held_rx && (!rx_valid[i] || rx_data[i] !== prior_rx))
                    $fatal(1,"receive data changed while stalled at endpoint %0d",i);
                if (held_tx && (!tx_valid[i] || tx_data[i] !== prior_tx))
                    $fatal(1,"test source changed while stalled at endpoint %0d",i);
                accepted=tx_valid[i] && tx_ready[i];
                if (accepted) begin
                    if (writes[i]>=MAX_WORDS || writes[i]-reads[i]>=DEPTH)
                        $fatal(1,"accepted excess data at endpoint %0d",i);
                    reference_words[i][writes[i]]=tx_data[i];
                    writes[i]=writes[i]+1;
                end
                if (rx_valid[i] && rx_ready[i]) begin
                    if (reads[PEER]>=writes[PEER] || rx_data[i] !== reference_words[PEER][reads[PEER]])
                        $fatal(1,"unexpected delivery at endpoint %0d word %0d",i,reads[PEER]);
                    reads[PEER]=reads[PEER]+1;
                end
                held_rx=rx_valid[i] && !rx_ready[i];
                held_tx=tx_valid[i] && !tx_ready[i];
                if (held_tx) stalls[i]=stalls[i]+1;
                prior_rx=rx_data[i];
                prior_tx=tx_data[i];
            end
        end
    end

    task automatic reset_link;
        begin
            #0.333;
            rst_n=0;
            goal[0]=0; goal[1]=0;
            mode[0]=1; mode[1]=1;
            #100;
            if ({tx_ready,rx_valid} !== 4'b0) $fatal(1,"active ports during reset");
            rst_n=1;
            #140;
            if (tx_ready !== 2'b11 || rx_valid !== 2'b00 ||
                (tx_used[0]|tx_used[1]|rx_used[0]|rx_used[1]) !== 0)
                $fatal(1,"link did not return to empty");
        end
    endtask

    task automatic isolate(input integer sender);
        integer peer, old_reads, old_stalls;
        begin
            peer=1-sender;
            mode[peer]=0;
            old_reads=reads[sender];
            old_stalls=stalls[sender];
            goal[sender]=writes[sender]+DEPTH+9;
            wait (stalls[sender]>old_stalls && full[sender] && rx_valid[peer]);
            if (writes[sender]-old_reads!=DEPTH || tx_ready[sender] !== 1'b0)
                $fatal(1,"did not backpressure at capacity");
            goal[peer]=writes[peer]+DEPTH/2;
            wait (reads[peer]==goal[peer]);
            if (reads[sender]!=old_reads || !full[sender]) $fatal(1,"blocked direction moved");
            mode[peer]=1;
            wait (reads[sender]==goal[sender]);
            #140;
        end
    endtask

    initial begin
        if (!$value$plusargs("SEED=%d",seed)) seed=27;
        salt=seed;
        $display("CLOCKS A_NS=%0d B_NS=%0d B_PHASE_PS=1701",SWAP_CLOCKS ? 14 : 10, SWAP_CLOCKS ? 10 : 14);
        reset_link();
        isolate(0);
        isolate(1);
        random_offers=1;
        mode[0]=2; mode[1]=2;
        goal[0]=writes[0]+3*DEPTH+17;
        goal[1]=writes[1]+3*DEPTH+31;
        wait (reads[0]==goal[0] && reads[1]==goal[1]);
        $display("DRAINED epoch=0 ab=%0d ba=%0d",reads[0],reads[1]);
        #140;
        mode[0]=0; mode[1]=0;
        goal[0]=writes[0]+DEPTH; goal[1]=writes[1]+DEPTH;
        wait (full==2'b11 && rx_valid==2'b11);
        $display("PRE_RESET AB_WR=%0d AB_RD=%0d BA_WR=%0d BA_RD=%0d",writes[0],reads[0],writes[1],reads[1]);
        epoch=1;
        reset_link();
        goal[0]=19; goal[1]=23;
        wait (reads[0]==19 && reads[1]==23);
        #140;
        if (rx_valid!==0 || writes[0]!=reads[0] || writes[1]!=reads[1])
            $fatal(1,"post-reset queue did not drain");
        $display("POST_RESET AB_WR=%0d AB_RD=%0d BA_WR=%0d BA_RD=%0d",writes[0],reads[0],writes[1],reads[1]);
        $display("IP_PASS DW=%0d AW=%0d STAGES=%0d SWAP=%0d SEED=%0d",DW,AW,SYNC_STAGES,SWAP_CLOCKS,seed);
        $finish;
    end

    initial begin
        #2000000;
        $fatal(1,"timeout writes=%0d/%0d reads=%0d/%0d",writes[0],writes[1],reads[0],reads[1]);
    end
endmodule
