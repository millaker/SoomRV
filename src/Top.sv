typedef struct packed
{
    logic ce;
    logic we;
    logic[3:0] wm;
    logic[29:0] addr;
    logic[31:0] data;
} CacheIF;

module Top
(
    input wire clk,
    input wire rst,
    input wire en,
    input wire[63:0] IN_instrRaw,

    output wire[28:0] OUT_instrAddr,
    output wire OUT_instrReadEnable,
    output wire OUT_halt
);

wire MC_DC_used;
CacheIF MC_DC_if;

wire MC_ce;
wire MC_we;
wire[9:0] MC_sramAddr;
wire[31:0] MC_extAddr;
wire[9:0] MC_progress;
wire MC_busy;
MemoryControllerSim memc
(
    .clk(clk),
    .rst(rst),
    
    .IN_ce(MC_ce),
    .IN_we(MC_we),
    .IN_sramAddr(MC_sramAddr),
    .IN_extAddr(MC_extAddr),
    .OUT_progress(MC_progress),
    .OUT_busy(MC_busy),
    
    .OUT_CACHE_used(MC_DC_used),
    .OUT_CACHE_we(MC_DC_if.we),
    .OUT_CACHE_ce(MC_DC_if.ce),
    .OUT_CACHE_wm(MC_DC_if.wm),
    .OUT_CACHE_addr(MC_DC_if.addr[9:0]),
    .OUT_CACHE_data(MC_DC_if.data),
    .IN_CACHE_data(DC_dataOut)
);
assign MC_DC_if.addr[29:10] = 0;

CacheIF CORE_DC_if;
always_comb begin
    CORE_DC_if.ce = CORE_writeEnable;
    CORE_DC_if.we = CORE_writeEnable;
    CORE_DC_if.wm = CORE_writeMask;
    CORE_DC_if.addr = CORE_writeAddr;
    CORE_DC_if.data = CORE_writeData;
end

wire CORE_writeEnable;
wire[31:0] CORE_writeData;
wire[29:0] CORE_writeAddr;
wire[3:0] CORE_writeMask;

wire CORE_readEnable;
wire[29:0] CORE_readAddr;
wire[31:0] CORE_readData;
Core core
(
    .clk(clk),
    .rst(rst),
    .en(en),
    
    .IN_instrRaw(IN_instrRaw),
    
    .OUT_MEM_writeAddr(CORE_writeAddr),
    .OUT_MEM_writeData(CORE_writeData),
    .OUT_MEM_writeEnable(CORE_writeEnable),
    .OUT_MEM_writeMask(CORE_writeMask),
    
    .OUT_MEM_readEnable(CORE_readEnable),
    .OUT_MEM_readAddr(CORE_readAddr),
    .IN_MEM_readData(CORE_readData),
    
    .OUT_instrAddr(OUT_instrAddr),
    .OUT_instrReadEnable(OUT_instrReadEnable),
    .OUT_halt(OUT_halt),
    
    .OUT_GPIO_oe(),
    .OUT_GPIO(),
    .IN_GPIO(16'b0),
    .OUT_SPI_clk(),
    .OUT_SPI_mosi(),
    .IN_SPI_miso(1'b0),
    
    .OUT_MC_ce(MC_ce),
    .OUT_MC_we(MC_we),
    .OUT_MC_sramAddr(MC_sramAddr),
    .OUT_MC_extAddr(MC_extAddr),
    .IN_MC_progress(MC_progress),
    .IN_MC_busy(MC_busy),
    
    .OUT_instrMappingMiss(),
    .IN_instrMappingBase(32'b0),
    .IN_instrMappingHalfSize(1'b0)
);

wire[31:0] DC_dataOut;

CacheIF DC_if;
assign DC_if = MC_DC_used ? MC_DC_if : CORE_DC_if;
MemRTL dcache
(
    .clk(clk),
    .IN_nce(!(!DC_if.ce && DC_if.addr < 1024)),
    .IN_nwe(DC_if.we),
    .IN_addr(DC_if.addr[15:0]),
    .IN_data(DC_if.data),
    .IN_wm(DC_if.wm),
    .OUT_data(DC_dataOut),
    
    .IN_nce1(CORE_readEnable),
    .IN_addr1(CORE_readAddr[15:0]),
    .OUT_data1(CORE_readData)
);

always@(posedge clk) begin
    if (!CORE_DC_if.ce && !CORE_DC_if.we && CORE_DC_if.wm == 4'b0001 && CORE_DC_if.addr == 30'h3F800000)
        $write("%c", CORE_DC_if.data[7:0]);
end

endmodule
