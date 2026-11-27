`timescale 1ns/1ps
// Each status output is paired with a clock that samples it halfway through the bit.
module duplex_example #(parameter DW=32) (
    input wire clk_a, clk_b, rst_n_async,
    output wire activity_clk_a, activity_clk_b,
    (* IOB = "TRUE" *) output reg activity_a=0, activity_b=0
);
    reg [31:0] data_a=32'h3f22101b, data_b=32'h73625241;
    reg [DW-1:0] sample_a=0, sample_b=0;
    wire [DW-1:0] received_a, received_b;
    wire tx_ready_a, tx_ready_b, rx_valid_a, rx_valid_b;
    reg [3:0] throttle_a=0, throttle_b=0;
    wire ready_a=throttle_a!=4'd2, ready_b=throttle_b!=4'd5;

    always @(posedge clk_a) begin
        throttle_a <= throttle_a+1'b1;
        if (tx_ready_a) data_a <= {data_a[30:0],data_a[31]^data_a[21]^data_a[1]^data_a[0]};
        if (rx_valid_a && ready_a) sample_a <= received_a;
        activity_a <= ^sample_a;
    end
    always @(posedge clk_b) begin
        throttle_b <= throttle_b+1'b1;
        if (tx_ready_b) data_b <= {data_b[30:0],data_b[31]^data_b[21]^data_b[1]^data_b[0]};
        if (rx_valid_b && ready_b) sample_b <= received_b;
        activity_b <= ^sample_b;
    end

    // Only the Artix-7 reference top uses device primitives. The IP is plain RTL.
    ODDR forward_a (.C(clk_a), .CE(1'b1), .D1(1'b0), .D2(1'b1),
                    .R(1'b0), .S(1'b0), .Q(activity_clk_a));
    ODDR forward_b (.C(clk_b), .CE(1'b1), .D1(1'b0), .D2(1'b1),
                    .R(1'b0), .S(1'b0), .Q(activity_clk_b));

    // The module below is created from the IP Catalog by the consumer script.
    duplex_i link (
        .clk_a(clk_a), .clk_b(clk_b), .rst_n_async(rst_n_async),
        .a_tx_valid(1'b1), .a_tx_ready(tx_ready_a), .a_tx_data(data_a[DW-1:0]),
        .b_tx_valid(1'b1), .b_tx_ready(tx_ready_b), .b_tx_data(data_b[DW-1:0]),
        .a_rx_ready(ready_a), .a_rx_valid(rx_valid_a), .a_rx_data(received_a),
        .b_rx_ready(ready_b), .b_rx_valid(rx_valid_b), .b_rx_data(received_b)
    );
endmodule
