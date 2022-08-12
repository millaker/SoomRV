
typedef struct packed 
{
    bit valid;
    bit flags;
    bit[5:0] tag;
    bit[4:0] name;
    bit[31:0] result;
} ROBEntry;

module ROB
#(
    // how many entries, ie how many instructions can we
    // speculatively execute?
    parameter LENGTH = 8,
    // how many ops are en/dequeued per cycle?
    parameter WIDTH = 1,
    // how many concurrent reads?
    parameter READ_WIDTH = 2
)
(
    input wire clk,
    input wire rst,

    input wire IN_valid[WIDTH-1:0],
    input wire[31:0] IN_results[WIDTH-1:0],
    input wire[5:0] IN_tags[WIDTH-1:0],
    input wire[4:0] IN_names[WIDTH-1:0],
    input wire IN_flags[WIDTH-1:0],

    input wire[5:0] IN_read_tags[READ_WIDTH-1:0],

    output wire OUT_full,

    output reg[31:0] OUT_results[WIDTH-1:0],
    output reg[4:0] OUT_names[WIDTH-1:0],
    output reg[5:0] OUT_tags[WIDTH-1:0],

    output reg[31:0] OUT_read_results[READ_WIDTH-1:0],
    output reg OUT_read_avail[READ_WIDTH-1:0]
);

assign OUT_full = 0; // placeholder

ROBEntry entries[LENGTH-1:0];

integer i;
integer j;

// Read logic, for forwarding uncommitted values to execution.
always @(*) begin
    for (i = 0; i < READ_WIDTH; i=i+1)
    begin
        OUT_read_avail[i] = 0;
        OUT_read_results[i] = {32{1'bx}};
    end

    // can you tell synthesis not to generate contention logic here?
    for (i = 0; i < LENGTH; i=i+1) begin
        for (j = 0; j < READ_WIDTH; j=j+1) begin
            if (entries[i].valid && entries[i].tag == IN_read_tags[j]) begin
                OUT_read_avail[j] = 1;
                OUT_read_results[j] = entries[i].result;
            end
        end
    end
end


wire doDequeue = 1; // placeholder
always_ff@(posedge clk) begin

    if (rst) begin
        for (i = 0; i < LENGTH; i=i+1) begin
            entries[i].valid <= 0;
        end
    end
    else begin
        // Dequeue and push forward fifo entries
        if (doDequeue) begin
            // Push forward fifo
            for (i = 0; i < LENGTH - WIDTH; i=i+1) begin
                entries[i] <= entries[i + WIDTH];
            end

            for (i = 0; i < WIDTH; i=i+1) begin
                OUT_results[i] <= entries[i].result;
                OUT_names[i] <= entries[i].valid ? entries[i].name : 0;
                OUT_tags[i] <= entries[i].tag;
                // TODO: handle exceptions here.
            end
        end

        // Enqueue if entries are unused (or if we just dequeued, which frees space).
        for (i = 0; i < WIDTH; i=i+1) begin
            if ((doDequeue || !entries[LENGTH - i - 1].valid)) begin
                entries[LENGTH - i - 1].valid <= IN_valid[i];
                entries[LENGTH - i - 1].flags <= 0;
                entries[LENGTH - i - 1].tag <= IN_tags[i];
                entries[LENGTH - i - 1].name <= IN_names[i];
                entries[LENGTH - i - 1].result <= IN_results[i];
            end
        end
    end
end


endmodule