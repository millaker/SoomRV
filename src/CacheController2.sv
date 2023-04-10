module CacheController
#(
    parameter SIZE=16,
    parameter ASSOC=4,
    parameter CLSIZE_E=8,
    localparam TOTAL_UOPS = 2
)
(
    input wire clk,
    input wire rst,
    
    input BranchProv IN_branch,
    input wire IN_SQ_empty,
    
    input wire IN_stall[TOTAL_UOPS-1:0],
    output wire OUT_stall[TOTAL_UOPS-1:0],
    
    input AGU_UOp IN_uopLd,
    output AGU_UOp OUT_uopLd,
    
    input ST_UOp IN_uopSt,
    output ST_UOp OUT_uopSt,
    
    output CTRL_MemC OUT_memc,
    input STAT_MemC IN_memc,
    
    input wire IN_fence,
    output wire OUT_fenceBusy
);

integer i;
integer j;

localparam LEN = SIZE / ASSOC;
localparam TAG_LEN = 32 - CLSIZE_E - $clog2(LEN);


typedef struct packed
{
    logic[TAG_LEN-1:0] addr;
    logic valid;
    logic dirty;
    logic used;
} CacheTableEntry;

typedef struct packed
{
    logic[31:0] addr;
    logic isMMIO;
    logic isLoad;
    AGU_Exception exception;
    logic valid;
} CommonUOp;

CommonUOp uops[TOTAL_UOPS-1:0];
always_comb begin
    uops[0].valid = IN_uopLd.valid && (!IN_branch.taken || $signed(IN_uopLd.sqN - IN_branch.sqN) <= 0);
    uops[0].exception = IN_uopLd.exception;
    uops[0].isLoad = 1;
    uops[0].addr = IN_uopLd.addr;

    uops[1].valid = IN_uopSt.valid;
    uops[1].exception = AGU_NO_EXCEPTION;
    uops[1].isLoad = 0;
    uops[1].addr = IN_uopSt.addr;
end

assign OUT_fenceBusy = 0;

CommonUOp outUops[TOTAL_UOPS-1:0];

CacheTableEntry ctable[LEN-1:0][ASSOC-1:0];

reg cacheHit[1:0];
reg[$clog2(ASSOC)-1:0] cacheHitIdx[1:0];

reg cacheFreeAvail[1:0];

reg[$clog2(ASSOC)-1:0] cacheFreeIdx[1:0];
reg[$clog2(ASSOC)-1:0] cacheEvictIdx[1:0];

reg[$clog2(LEN)-1:0] cacheIdx[1:0];

always_comb begin
    
    for (i = 0; i < TOTAL_UOPS; i=i+1) begin
        cacheHit[i] = 0;
        cacheFreeAvail[i] = 0;
        cacheHitIdx[i] = 'x;
        cacheFreeIdx[i] = 'x;
        cacheEvictIdx[i] = 'x;

        cacheIdx[i] = uops[i].addr[CLSIZE_E+$clog2(LEN)-1:CLSIZE_E];

        for (j = 0; j < ASSOC; j=j+1)
            if (ctable[cacheIdx[i]][j].valid &&
                ctable[cacheIdx[i]][j].addr == uops[i].addr[31:CLSIZE_E+$clog2(LEN)]) begin
                
                cacheHit[i] = 1;
                cacheHitIdx[i] = j[$clog2(ASSOC)-1:0];
            end

        for (j = 0; j < ASSOC; j=j+1)
            if (!ctable[cacheIdx[i]][j].valid) begin
                cacheFreeIdx[i] = j[$clog2(ASSOC)-1:0];
                cacheFreeAvail[i] = 1;
            end

        for (j = 0; j < ASSOC; j=j+1)
            if (!ctable[cacheIdx[i]][j].used)
                cacheEvictIdx[i] = j[$clog2(ASSOC)-1:0];
    end
end

enum logic[2:0]
{
    IDLE, EVICT_RQ, EVICT_ACTIVE, LOAD_RQ, LOAD_ACTIVE
} state;

reg cacheMiss[1:0];

wire[$clog2(LEN)-1:0] evictIdx = OUT_memc.sramAddr[CLSIZE_E-2+:$clog2(LEN)];
wire[$clog2(ASSOC)-1:0] evictAssocIdx = OUT_memc.sramAddr[CLSIZE_E+$clog2(LEN)-2+:$clog2(ASSOC)];

reg isMMIO[TOTAL_UOPS-1:0];
reg isCacheHit[TOTAL_UOPS-1:0];
reg isCachePassthru[TOTAL_UOPS-1:0];
always_comb begin
    for (i = 0; i < TOTAL_UOPS; i=i+1) begin
        
        isMMIO[i] = uops[i].valid && `IS_MMIO_PMA(uops[i].addr);

        isCacheHit[i] = uops[i].valid && !`IS_MMIO_PMA(uops[i].addr) && cacheHit[i];

        isCachePassthru[i] = uops[i].valid && !`IS_MMIO_PMA(uops[i].addr) &&
            state == LOAD_ACTIVE &&
            OUT_memc.extAddr[29:CLSIZE_E-2] == uops[i].addr[31:CLSIZE_E] &&
            IN_memc.progress[CLSIZE_E-3:0] > uops[i].addr[CLSIZE_E-1:2];

        OUT_stall[i] = (uops[i].valid && !isMMIO[i] && !isCacheHit[i] && !isCachePassthru[i]) || IN_stall[i];
    end
end

ST_UOp outStUOp_r;
AGU_UOp outLdUOp_r;

always_comb begin
    OUT_uopLd = outLdUOp_r;
    OUT_uopLd.valid = outUops[0].valid;
    OUT_uopLd.addr = outUops[0].addr;
    OUT_uopLd.isMMIO = outUops[0].isMMIO;

    OUT_uopSt = outStUOp_r;
    OUT_uopSt.valid = outUops[1].valid;
    OUT_uopSt.addr = outUops[1].addr;
    OUT_uopSt.isMMIO = outUops[1].isMMIO;
end

always_ff@(posedge clk) begin
   
    reg temp = 0;

    if (rst) begin
        OUT_memc.cmd <= MEMC_NONE;
        state <= IDLE;
        for (i = 0; i < TOTAL_UOPS; i=i+1) begin
            outUops[i] <= 'x;
            outUops[i].valid <= 0;
        end
    end
    else begin
        // Evict/Load State Machine
        case (state)
            default: state <= IDLE;
            LOAD_RQ: begin
                if (IN_memc.busy && IN_memc.rqID == 0) begin
                    OUT_memc.cmd <= MEMC_NONE;
                    state <= LOAD_ACTIVE;
                end
            end
            LOAD_ACTIVE: begin
                if (!IN_memc.busy) begin
                    state <= IDLE;
                    ctable[evictIdx][evictAssocIdx].valid <= 1;
                    ctable[evictIdx][evictAssocIdx].used <= 0;
                    ctable[evictIdx][evictAssocIdx].addr <= OUT_memc.extAddr[29:$clog2(LEN)+CLSIZE_E-2];
                end
            end
            EVICT_RQ: begin
                if (IN_memc.busy && IN_memc.rqID == 0) begin
                    OUT_memc.cmd <= MEMC_NONE;
                    state <= EVICT_ACTIVE;
                end
            end
            EVICT_ACTIVE: begin
                if (!IN_memc.busy) begin
                    state <= IDLE;
                end
            end
        endcase

        // Incoming UOps handling
        for (i = 0; i < TOTAL_UOPS; i=i+1) begin
            
            if (!IN_stall[i]) begin
                outUops[i] <= 'x;
                outUops[i].valid <= 0;
            end

            if (uops[i].valid) begin
                if (isMMIO[i] && !OUT_stall[i]) begin
                    outUops[i] <= uops[i];
                    outUops[i].isMMIO <= 1;
                    outUops[i].valid <= 1;
                    if (i == 0) outLdUOp_r <= IN_uopLd;
                    if (i == 1) outStUOp_r <= IN_uopSt;
                end
                else if ((isCacheHit[i] || isCachePassthru[i]) && !OUT_stall[i]) begin
                    outUops[i] <= uops[i];
                    outUops[i].isMMIO <= 0;
                    outUops[i].valid <= 1;

                    if (isCacheHit[i]) begin
                        outUops[i].addr <= {{{32-CLSIZE_E-$clog2(SIZE)}{1'b0}}, cacheHitIdx[i], cacheIdx[i], uops[i].addr[CLSIZE_E-1:0]};
                        if (!uops[i].isLoad) ctable[cacheIdx[i]][cacheHitIdx[i]].dirty <= 1;
                        // maybe manage used in separate array?
                        for (j = 0; j < ASSOC; j=j+1) 
                            ctable[cacheIdx[i]][j].used <= 0;
                        ctable[cacheIdx[i]][cacheHitIdx[i]].used <= 1;
                    end
                    else begin // if (isCachePassthru[i])
                        outUops[i].addr <= {{{32-CLSIZE_E-$clog2(SIZE)}{1'b0}}, evictAssocIdx, evictIdx, uops[i].addr[CLSIZE_E-1:0]};

                        if (!uops[i].isLoad) ctable[evictIdx][evictAssocIdx].dirty <= 1;
                        ctable[evictIdx][evictAssocIdx].used <= 1;
                    end

                    if (i == 0) outLdUOp_r <= IN_uopLd;
                    if (i == 1) outStUOp_r <= IN_uopSt;
                end
                else if (!cacheHit[i] && state == IDLE && cacheFreeAvail[i] && !temp) begin
                    state <= LOAD_RQ;

                    OUT_memc.cmd <= MEMC_CP_EXT_TO_CACHE;
                    OUT_memc.sramAddr <= {cacheFreeIdx[i], cacheIdx[i], {(CLSIZE_E-2){1'b0}}};
                    OUT_memc.extAddr <= {uops[i].addr[31:CLSIZE_E], {(CLSIZE_E-2){1'b0}}};
                    OUT_memc.cacheID <= 0;
                    OUT_memc.rqID <= 0;

                    temp = 1;
                end
                else if (!cacheHit[i] && state == IDLE && !temp) begin
                    state <= EVICT_RQ;
                    
                    // there might be accesses that come through in the same cycle...
                    ctable[cacheIdx[i]][cacheEvictIdx[i]].valid <= 0;
                    ctable[cacheIdx[i]][cacheEvictIdx[i]].dirty <= 0;

                    // TODO: do not evict if not dirty
                    OUT_memc.cmd <= MEMC_CP_CACHE_TO_EXT;
                    OUT_memc.sramAddr <= {cacheEvictIdx[i], cacheIdx[i], {(CLSIZE_E-2){1'b0}}};
                    OUT_memc.extAddr <= {ctable[cacheIdx[i]][cacheEvictIdx[i]].addr, cacheIdx[i], {(CLSIZE_E-2){1'b0}}};
                    OUT_memc.cacheID <= 0;
                    OUT_memc.rqID <= 0;

                    temp = 1;
                end
            end
        end
    end
end

endmodule
