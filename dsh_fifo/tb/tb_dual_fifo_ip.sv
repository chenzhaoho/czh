`timescale 1ns/1ps
// Black-box IP test. The scoreboard only observes ready/valid interface pins.
module tb_dual_fifo_ip #(
    parameter integer DW=32, AW=8, SYNC_STAGES=2, SWAP_CLOCKS=0, CLOCK_CASE=0
);
    localparam integer DEPTH=1<<AW, MAX_WORDS=8*DEPTH+256;
    // 0: reference clocks, 1: coincident edges, 2: asymmetric 50:1 clock ratio.
    localparam integer SLOW_HALF=CLOCK_CASE==2 ? 50 : (CLOCK_CASE==1 ? 5 : 7);
    localparam integer FAST_HALF=CLOCK_CASE==2 ? 1 : 5;
    localparam integer HALF_A=SWAP_CLOCKS ? SLOW_HALF : FAST_HALF;
    localparam integer HALF_B=SWAP_CLOCKS ? FAST_HALF : SLOW_HALF;
    localparam integer PHASE_B_PS=CLOCK_CASE==1 ? 0 : 1701;
    localparam integer SETTLE_NS=CLOCK_CASE==0 ? 140 : 2*SLOW_HALF*(SYNC_STAGES+8);
    localparam integer RESET_NS=CLOCK_CASE==0 ? 100 : SETTLE_NS;
    reg [1:0] clk=0, tx_valid=0, rx_ready=0;
    reg [1:0] clock_run=2'b11;
    reg rst_n=0, random_offers=0;
    reg [DW-1:0] tx_data[0:1];
    wire [DW-1:0] rx_data[0:1];
    wire [1:0] tx_ready, rx_valid, full;
    wire [AW:0] tx_used[0:1], rx_used[0:1];
    integer goal[0:1], mode[0:1], writes[0:1], reads[0:1], stalls[0:1];
    reg [DW-1:0] reference_words[0:1][0:MAX_WORDS-1];
    integer seed, epoch=0;
    reg [31:0] salt;

    always #(HALF_A) if (clk[0] || clock_run[0]) clk[0]=~clk[0];
    initial begin
        if (PHASE_B_PS!=0) #(PHASE_B_PS/1000.0);
        forever #(HALF_B) if (clk[1] || clock_run[1]) clk[1]=~clk[1];
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

        always @(negedge clk[i] or negedge rst_n) begin
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

        always @(posedge clk[i] or negedge rst_n) begin
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
                if (tx_used[i]<writes[i]-reads[i] || rx_used[i]>writes[PEER]-reads[PEER])
                    $fatal(1,"local occupancy was optimistic at endpoint %0d",i);
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
            #(RESET_NS);
            if ({tx_ready,rx_valid} !== 4'b0) $fatal(1,"active ports during reset");
            rst_n=1;
            #(SETTLE_NS);
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
            #(SETTLE_NS);
        end
    endtask

    task automatic test_stopped_clock(input integer stopped);
        integer running, base_writes, base_reads, reverse_goal;
        begin
            running=1-stopped;
            random_offers=0;
            mode[running]=0;
            goal[stopped]=writes[stopped]+DEPTH/2;
            wait (writes[stopped]==goal[stopped] && !tx_valid[stopped]);
            reverse_goal=goal[stopped];

            #0.037;
            clock_run[stopped]=0;
            wait (clk[stopped]==0);
            base_writes=writes[running];
            base_reads=reads[running];
            goal[running]=base_writes+DEPTH+3;
            mode[running]=1;
            wait (full[running] && tx_valid[running] && reads[stopped]==reverse_goal);
            #(SETTLE_NS);
            if (writes[running]-base_writes!=DEPTH || reads[running]!=base_reads ||
                tx_ready[running]!==1'b0 || tx_used[running]!==DEPTH)
                $fatal(1,"stopped receiver accepted more than FIFO capacity");
            clock_run[stopped]=1;
            wait (reads[running]==goal[running]);
            #(SETTLE_NS);
            if ((tx_used[0]|tx_used[1]|rx_used[0]|rx_used[1])!==0 || rx_valid!==2'b00)
                $fatal(1,"clock restart did not drain both queues");

            // Queue data, assert common reset with the destination clock still stopped.
            #0.037;
            clock_run[stopped]=0;
            wait (clk[stopped]==0);
            goal[running]=writes[running]+9;
            wait (writes[running]==goal[running]);
            #(SETTLE_NS);
            rst_n=0;
            goal[0]=0; goal[1]=0;
            #(RESET_NS);
            if ({tx_ready,rx_valid,full}!==6'b0 ||
                (tx_used[0]|tx_used[1]|rx_used[0]|rx_used[1])!==0)
                $fatal(1,"asynchronous reset failed while a clock was stopped");
            rst_n=1;
            #(SETTLE_NS);
            if (tx_ready[stopped]!==1'b0 || tx_ready[running]!==1'b1 || rx_valid!==2'b00)
                $fatal(1,"reset released on a stopped clock");
            epoch=epoch+1;
            goal[running]=13;
            wait (writes[running]==13);
            #(SETTLE_NS);
            clock_run[stopped]=1;
            goal[stopped]=17;
            wait (reads[running]==13 && reads[stopped]==17);
            #(SETTLE_NS);
            if ((tx_used[0]|tx_used[1]|rx_used[0]|rx_used[1])!==0 || rx_valid!==2'b00)
                $fatal(1,"fresh traffic did not drain after a stopped-clock reset");
            $display("CLOCK_PAUSE_PASS stopped=%0d capacity=%0d reverse=%0d",stopped,DEPTH,DEPTH/2);
        end
    endtask

    initial begin
        if (!$value$plusargs("SEED=%d",seed)) seed=27;
        salt=seed;
        $display("CLOCKS A_NS=%0d B_NS=%0d B_PHASE_PS=%0d",2*HALF_A,2*HALF_B,PHASE_B_PS);
        reset_link();
        isolate(0);
        isolate(1);
        random_offers=1;
        mode[0]=2; mode[1]=2;
        goal[0]=writes[0]+3*DEPTH+17;
        goal[1]=writes[1]+3*DEPTH+31;
        wait (reads[0]==goal[0] && reads[1]==goal[1]);
        $display("DRAINED epoch=0 ab=%0d ba=%0d",reads[0],reads[1]);
        #(SETTLE_NS);
        mode[0]=0; mode[1]=0;
        goal[0]=writes[0]+DEPTH; goal[1]=writes[1]+DEPTH;
        wait (full==2'b11 && rx_valid==2'b11);
        $display("PRE_RESET AB_WR=%0d AB_RD=%0d BA_WR=%0d BA_RD=%0d",writes[0],reads[0],writes[1],reads[1]);
        epoch=1;
        reset_link();
        goal[0]=19; goal[1]=23;
        wait (reads[0]==19 && reads[1]==23);
        #(SETTLE_NS);
        if (rx_valid!==0 || writes[0]!=reads[0] || writes[1]!=reads[1])
            $fatal(1,"post-reset queue did not drain");
        $display("POST_RESET AB_WR=%0d AB_RD=%0d BA_WR=%0d BA_RD=%0d",writes[0],reads[0],writes[1],reads[1]);
        if (CLOCK_CASE!=0) begin
            test_stopped_clock(0);
            test_stopped_clock(1);
        end
        $display("IP_PASS DW=%0d AW=%0d STAGES=%0d SWAP=%0d SEED=%0d",DW,AW,SYNC_STAGES,SWAP_CLOCKS,seed);
        $finish;
    end

    initial begin
        #2000000;
        $fatal(1,"timeout writes=%0d/%0d reads=%0d/%0d",writes[0],writes[1],reads[0],reads[1]);
    end
endmodule
