`timescale 1ns/1ps
//=============================================================================
// deserializer2 — 1:2 串并转换（把 2Fs 的串行流拆回一个 Fs 拍的两相）
//-----------------------------------------------------------------------------
// serializer2 的逆过程：DUC 方向是"两相并一相"，DDC 方向是"一相拆两相"。
//
// 时钟关系（和 serializer2 完全对称）：
//   clk2x = 2Fs，串行输入 d 在这个域里，每个 clk2x 周期一个样本；
//   clk   = Fs，并行输出 d_e/d_o 在这个域里，每个 clk 更新一次。
//   clk2x 必须和 clk 同源、2 倍频、相位错开约 90°。
//
// 采样沿：**negedge clk2x**。
//   serializer 在 clk 上升沿后的第一个 clk2x posedge 输出偶相、
//   下一个 posedge 输出奇相；这里在随后的 negedge 采样，采样点落在
//   数据眼图中间，不会和发送沿抢。这是标准 source-synchronous 做法。
//
// 定帧：和 serializer2 一样，用 clk 的上升沿给"偶/奇"定帧：
//   在 clk2x negedge 采样 clk，检测到 clk 上升沿后：
//       · 采到的第一个样本是偶相 → d_e；
//       · 下一个 negedge 采到的是奇相 → d_o。
//   这样复位先后不会让偶/奇相互换（第一版自由跑 ph 的教训，见 serializer2）。
//
// 延迟：d 在 clk2x 的 negedge 被采，d_e/d_o 在下一个 clk 上升沿被 DDC 读到 ——
//       端到端比串行流晚约 1 个 clk 周期。
//=============================================================================

module deserializer2 #(
    parameter integer DW = 15          // 数据位宽
)(
    input  wire          clk,          // Fs：并行数据域
    input  wire          clk2x,        // 2Fs：串行输入域（同源、2 倍、相位错开）
    input  wire          rst_n,        // 异步复位，低有效
    input  wire [DW-1:0] d,            // 串行流（每个 clk2x 一个样本）
    output reg  [DW-1:0] d_e,          // 偶相 y[2n]
    output reg  [DW-1:0] d_o           // 奇相 y[2n+1]
);

    reg        clk_d;                  // clk 在 clk2x 域的上一拍采样
    reg        frame;                  // clk 上升沿的"定帧"脉冲（posedge 生成、negedge 使用）
    reg        ph;                     // 0 = 本帧还没收到偶相；1 = 已收到偶相、等奇相

    // 定帧脉冲在 **posedge clk2x** 生成：clk 上升沿后的第一个 clk2x 沿。
    // 这样它和 serializer 的帧边界是同一个沿，不会早半个周期。
    always @(posedge clk2x or negedge rst_n) begin
        if (!rst_n) begin
            clk_d <= 1'b0;
            frame <= 1'b0;
        end else begin
            clk_d <= clk;
            frame <= clk & ~clk_d;
        end
    end

    // 数据在 **negedge clk2x** 采：发送端在 posedge 更新，接收端晚半个周期，
    // 采样点落在数据眼图中间。
    always @(negedge clk2x or negedge rst_n) begin
        if (!rst_n) begin
            ph  <= 1'b0;
            d_e <= {DW{1'b0}};
            d_o <= {DW{1'b0}};
        end else if (frame) begin
            // 定帧沿之后的第一个 negedge：串行流上的第一个样本是偶相
            d_e <= d;
            ph  <= 1'b1;
        end else if (ph) begin
            // 同一帧的第二个 negedge：奇相
            d_o <= d;
            ph  <= 1'b0;
        end
    end

    // ── CDC 说明 ────────────────────────────────────────────────────
    // d 在 clk2x 域采样，d_e/d_o 被 clk 域读取。d_e/d_o 在半个 clk 周期内
    // 稳定，clk 的沿读到的是一整对；这是同步多周期路径，不是异步 CDC。
    // 板上回环时，串行链路要留够 Tco/布线余量（50 MHz 下半个周期 10 ns，
    // 非常宽松）；仿真里 TB 可以直接连，因为采样沿和发送沿已经错开半拍。

endmodule
