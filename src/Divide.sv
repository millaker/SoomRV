`ifndef DIVIDE_SV
`define DIVIDE_SV

`include "Include.sv"

module Divide (
  input wire clk,
  input wire rst,
  input wire en,

  output wire OUT_busy,

  input BranchProv IN_branch,

  input  EX_UOp  IN_uop,
  output RES_UOp OUT_uop
);


  EX_UOp uop;
  reg [6:0] cnt;
  reg [128:0] r;
  reg [63:0] d;
  reg invert;

  wire [64:0] d_inv = -{1'b0, d};
  wire [63:0] q = r[63:0];

  reg running;

  assign OUT_busy = running && (cnt != 0 && cnt != 63);

  always_ff @(posedge clk  /*or posedge rst*/) begin

    running <= 0;
    OUT_uop <= 'x;
    OUT_uop.valid <= 0;

    if (rst) begin
      uop <= EX_UOp'{valid: 0, default: 'x};
      cnt <= 'x;
      invert <= 'x;
      r <= 'x;
      d <= 'x;
    end else begin
      if (en && IN_uop.valid && (!IN_branch.taken || $signed(IN_uop.sqN - IN_branch.sqN) <= 0)) begin
        if(IN_uop.opcode <= DIV_REMU) begin
          running <= 1;
          uop <= IN_uop;
          cnt <= 63;

          if (IN_uop.opcode == DIV_DIV) begin
            invert <= (IN_uop.srcA[63] ^ IN_uop.srcB[63]) && (IN_uop.srcB != 0);
            r <= {
            65'b0, (IN_uop.srcA[63] ? (-IN_uop.srcA) : IN_uop.srcA)
            };
            d <= IN_uop.srcB[63] ? (-IN_uop.srcB) : IN_uop.srcB;
          end else if (IN_uop.opcode == DIV_REM) begin
            invert <= IN_uop.srcA[63];
            r <= {
            65'b0, (IN_uop.srcA[63] ? (-IN_uop.srcA) : IN_uop.srcA)
            };
            d <= IN_uop.srcB[63] ? (-IN_uop.srcB) : IN_uop.srcB;
          end else begin
            invert <= 0;
            r <= {65'b0, IN_uop.srcA};
            d <= IN_uop.srcB;
          end
          OUT_uop.valid <= 0;
        end else begin
          running <= 1;
          uop <= IN_uop;
          cnt <= 31;

          if (IN_uop.opcode == DIV_DIVW) begin
            invert <= (IN_uop.srcA[31] ^ IN_uop.srcB[31]) && (IN_uop.srcB != 0);
            r <= {
            97'b0, (IN_uop.srcA[31] ? (-(IN_uop.srcA[31:0])) : IN_uop.srcA[31:0])
            };
            d <= IN_uop.srcB[31] ? (-IN_uop.srcB) : IN_uop.srcB;
          end else if (IN_uop.opcode == DIV_REMW) begin
            invert <= IN_uop.srcA[31];
            r <= {
            97'b0, (IN_uop.srcA[31] ? (-(IN_uop.srcA[31:0])) : IN_uop.srcA[31:0])
            };
            d <= {32'd0, IN_uop.srcB[31] ? (-(IN_uop.srcB[31:0])) : IN_uop.srcB[31:0]};
          end else begin
            invert <= 0;
            r <= {97'd0, IN_uop.srcA[31:0]};
            d <= {32'd0, IN_uop.srcB[31:0]};
          end
          OUT_uop.valid <= 0;
        end

      end else if (running) begin

        if (IN_branch.taken && $signed(IN_branch.sqN - uop.sqN) < 0) begin
          running <= 0;
          uop.valid <= 0;
          OUT_uop.valid <= 0;
        end else if (cnt != 127) begin
          running <= 1;
          r <= (r << 1) + {r[128] ? {1'b0, d} : d_inv, 63'b0, !r[128]};
          cnt <= cnt - 1;
          OUT_uop.valid <= 0;
        end else begin
          reg [63:0] qRestored = (q - (~q)) - (r[128] ? 1 : 0);
          reg [63:0] remainder = (r[128] ? (r[127:64] + d) : r[127:64]);

          running <= 0;

          OUT_uop.sqN <= uop.sqN;
          OUT_uop.tagDst <= uop.tagDst;
          OUT_uop.doNotCommit <= 0;

          OUT_uop.flags <= FLAGS_NONE;
          OUT_uop.valid <= 1;
          if (uop.opcode == DIV_REM || uop.opcode == DIV_REMU || uop.opcode == DIV_REMW || uop.opcode == DIV_REMUW)
            OUT_uop.result <= invert ? (-remainder) : remainder;
          else OUT_uop.result <= invert ? (-qRestored) : qRestored;
        end
      end
    end
  end



endmodule

`endif
