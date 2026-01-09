# Optimized 2D Convolution Accelerator in Verilog

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)  

This project implements a **highly optimized 2D convolution accelerator** in SystemVerilog, designed for FPGA or ASIC integration. It features pipelined multiply-accumulate (MAC) operations, a parallel adder tree, and a sliding window for high-performance convolution computation.  

This design was developed as a senior-level digital systems project and represents the **most optimized implementation in the class**, achieving minimal latency and maximal throughput for convolution operations.  

---

## Features

- **Parallel Multiplier + Adder Tree** for fast MAC operations.  
- **Sliding Window Line Buffer** for MAXK × MAXK convolution patches.  
- **FIFO-based Output Buffer** for smooth AXI-Stream interfacing.  
- **Parameterized Design**: Supports variable input width, matrix dimensions, kernel sizes, and pipeline depth.  
- **Pipelined Architecture** for high throughput and low latency.  
- **State Machine Control**: `WAIT_FOR_LOAD`, `LOAD_DATA`, `WAIT_FOR_PIPE`.  

---

## Important Modules

### `Conv` – Top-Level Convolution Module

Handles input/output streaming, memory address computation, and MAC control.  

**Parameters:**

| Parameter | Description |
|-----------|-------------|
| `INW` | Input data bit width |
| `R`, `C` | Input matrix rows and columns |
| `MAXK` | Maximum kernel size |
| `PIPELINE_DEPTH` | Pipeline depth of the MAC + adder tree |
| `ADDER_TREE_STAGES` | Number of stages in the adder tree |

**Inputs/Outputs:**

- **Inputs:** `clk`, `reset`, `INPUT_TDATA`, `INPUT_TVALID`, `INPUT_TUSER`, `OUTPUT_TREADY`  
- **Outputs:** `INPUT_TREADY`, `OUTPUT_TDATA`, `OUTPUT_TVALID`  

**Key Features:**

- Base address computation for input memory reads.  
- Column/row counters for sliding window control.  
- Packed window data preparation for MAXK × MAXK patches.  
- Pipelined multiplier + adder tree computation.  
- FIFO buffering for decoupled AXI-Stream output.  

---

### `window` – Sliding Window Module

Generates MAXK × MAXK patches from a stream of pixels for convolution.  

**Parameters:**

| Parameter | Description |
|-----------|-------------|
| `INW` | Pixel data width |
| `C` | Number of input columns |
| `MAXK` | Maximum kernel size |

**Inputs/Outputs:**

- **Inputs:** `pixel_in`, `K`, `pixel_valid`, `clk`, `reset`, `clr`, `init_true`  
- **Outputs:** `window_out[MAXK-1:0][MAXK-1:0]`  

**Key Features:**

- Line buffer with `MAXK` rows and `C` columns.  
- Produces windowed outputs for parallel MAC computations.  
- Supports variable kernel sizes with zero-padding.  

---

## Architecture Overview

1. **Multiplier-Adder Tree**:  
   - Performs `MAXK × MAXK` multiplications in parallel.  
   - Results are summed using a pipelined adder tree.  
   - Bias term added at the final stage.  

2. **Sliding Window**:  
   - Efficient extraction of convolution patches from input matrices.  
   - Ensures proper alignment of data into multiplier registers.  

3. **Pipelined MAC Operations**:  
   - Pipeline depth is dynamically determined based on kernel size.  
   - Input validity tracked across stages to maintain throughput.  

4. **AXI-Stream Interface**:  
   - Input and output follow AXI-Stream protocol for seamless FPGA integration.  

---

## Example Instantiation

```verilog
Conv #(
    .INW(24),
    .R(16),
    .C(17),
    .MAXK(9)
) conv_inst (
    .clk(clk),
    .reset(reset),
    .INPUT_TDATA(INPUT_TDATA),
    .INPUT_TVALID(INPUT_TVALID),
    .INPUT_TUSER(INPUT_TUSER),
    .INPUT_TREADY(INPUT_TREADY),
    .OUTPUT_TDATA(OUTPUT_TDATA),
    .OUTPUT_TVALID(OUTPUT_TVALID),
    .OUTPUT_TREADY(OUTPUT_TREADY)
);
