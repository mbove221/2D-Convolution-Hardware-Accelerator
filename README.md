# Optimized 2D Convolution Hardware Accelerator (SystemVerilog)

This repository implements a **high-performance, fully pipelined 2D convolution accelerator** in SystemVerilog, targeting FPGA or ASIC-style designs.  
The architecture emphasizes **timing closure, throughput maximization, and clean pipeline control**, rather than algorithmic novelty.

The optimized design achieved the **highest performance in the course (Ranked #1 / 40+ students)**, reaching **1.0 GHz Fmax** and a **~4.7× throughput improvement** over the baseline implementation through aggressive pipelining and parallelism.

---

## Key Results

- **Achieved Frequency:** 1.0 GHz (post-synthesis) for INW = 12, R = 9, C = 8, MAXK = 5
- **Throughput:** 1 output per cycle (after pipeline fill)  
- **Latency (once system is ready after loading inputs):** ADDER_TREE_STAGES + MULT_STAGES + 1 cycles
- **Speedup:** ~4.7× vs unoptimized design  
- **Design Style:** Fully synchronous, deeply pipelined, parameterized  

---

## Architecture Overview

The accelerator consists of four primary subsystems:

1. Sliding window line buffer  
2. Fully pipelined and parallelized multipliers and adder tree
3. FIFO-buffered AXI-Stream output interface  

High throughput is achieved by **eliminating long combinational paths**, **parallelizing** independent computations, and ensuring every computation stage is **explicitly registered and validity-tracked**.

---

## High-Level Dataflow

1. Input pixels stream in via AXI-Stream (stored in main memory as well)  
2. A sliding window assembles `MAXK × MAXK` convolution patches 
3. All kernel multiplications execute **in parallel**  
4. Partial products are summed using a **pipelined adder tree**  
5. Results are buffered in a FIFO and streamed out independently

---

## Performance Optimizations

### 1. Critical Path Elimination
The baseline design contained a long combinational MAC path.  
This was resolved by:
- Introducing multi-stage pipelined multipliers  
- Registering all adder tree stages  
- combinational depth  

---

### 2. Fully Pipelined multipliers + Adder Tree
- `MAXK × MAXK` multipliers operate in parallel  
- Results are summed using a balanced adder tree  
- Pipeline depth is statically determined and tracked  

Example:
```verilog
localparam PIPELINE_DEPTH = ADDER_TREE_STAGES
                          + MULT_PIPE_STAGES
                          + OUTPUT_REG;
```
This enables one output per cycle after pipeline fill.

### 3. Explicit Pipeline Validity Tracking


To ensure correctness and simplify verification, a `valid` signal is propagated through **every pipeline stage**, rather than relying on implicit timing assumptions.


```verilog
logic input_valid_reg [PIPELINE_DEPTH];
```

Each stage registers both data and its associated validity bit, ensuring:
- Deterministic pipeline behavior  
- Correct operation under stalls and backpressure  
- Simplified debugging and verification  

This mirrors production RTL practices and avoids timing-dependent behavior that can arise in deeply pipelined designs.

---

### 4. Decoupled Output via FIFO

A FIFO buffers convolution results, allowing:
- Continuous pipeline operation  
- Clean handling of downstream backpressure  
- AXI-Stream compliance without stalling computation  

This decoupling ensures the compute pipeline can run at full throughput regardless of output readiness.

---

## Module Overview

### `Conv.sv` — Top-Level Convolution Engine

Responsible for:
- AXI-Stream input/output interfaces  
- Sliding window coordination  
- MAC pipeline control  
- FIFO-based output buffering  

**Key Properties**
- Parameterized dimensions and bit-widths  
- Deterministic latency  
- Explicit FSM control  

---

### `input_mems.sv` — AXI-Stream Input Loader & Memory Controller

This module manages all **input-side data movement and control**, bridging the AXI-Stream interface with on-chip storage for convolution.

It is responsible for:
- Loading convolution weights (`W`)
- Loading input feature maps (`X`)
- Capturing kernel size (`K`) and bias (`B`)
- Coordinating safe handoff to the compute pipeline

---

#### AXI-Stream Protocol Handling

The module consumes AXI-Stream data (`AXIS_TDATA`, `AXIS_TVALID`, `AXIS_TREADY`) with semantic encoding via `AXIS_TUSER`:

- `AXIS_TUSER[K_BITS:1]` → kernel size `K`
- `AXIS_TUSER[0]` → `new_W` flag indicating whether weights must be reloaded

This allows dynamic reconfiguration of the convolution kernel **without redesign or recompilation**.

---

#### Internal Memory Architecture

- **X Memory**: Stores the input feature map (`R × C`)
- **W Memory**: Stores the kernel weights (`K × K`)
- Independent write counters and address multiplexers allow:
  - Streaming writes during load
  - Random-access reads during computation

Address selection is handled via 2:1 muxes, enabling seamless transition from load phase to compute phase.

---

#### Multi-Stage Load FSM

A dedicated FSM guarantees correct sequencing and data integrity:

| State | Function |
|------|---------|
| `WAIT_FOR_READY` | Accepts first AXI-Stream word and decodes mode |
| `LOAD_W_MATRIX` | Streams `K × K` kernel weights |
| `LOAD_B_VAL` | Captures bias value |
| `LOAD_X_MATRIX` | Streams `R × C` input feature map |
| `LOAD_DONE` | Signals completion and blocks new inputs |

The `inputs_loaded` signal asserts **only when all required data is safely stored**, preventing premature computation.

---

#### Deterministic Control & Reset Behavior

- Independent reset control for X and W counters
- Clean transition between convolution runs via `compute_finished`
- No inferred latches or ambiguous control paths

All state transitions and enables are fully specified, making the design robust under simulation and synthesis.

---

#### Why This Module Matters

`input_mems.sv` decouples **data ingestion** from **computation**, enabling:
- High-throughput streaming inputs
- Clean kernel reconfiguration
- Predictable compute startup latency

This separation mirrors real-world accelerator architectures used in **ASICs, FPGAs, and SoCs**, and is critical for scalable, reusable hardware design.

---

### `window.sv` — Sliding Window Line Buffer

Generates `MAXK × MAXK` pixel patches from streaming input.

**Features**
- Multi-line buffering with column indexing  
- Deterministic window alignment  
- Variable kernel size support with zero padding  

---

### `MAC (included in Conv.sv)` — Parallel Multiply–Accumulate Engine

- Performs `MAXK × MAXK` multiplications per cycle  
- Feeds a balanced, pipelined adder tree  
- Designed for high-frequency synthesis  

---

### `fifo_out.sv` — Output Buffer

- Decouples compute pipeline from output interface  
- Handles AXI-Stream backpressure cleanly  
- Maintains peak throughput  

---

## Verification

- Cycle-accurate simulation in QuestaSim  
- Randomized test vectors  
- Pipeline latency and correctness validated  
- Valid signal propagation verified across all stages  

---

## Why This Design Matters

This project demonstrates:
- Timing-driven RTL design  
- High-frequency pipeline architecture  
- Scalable and parameterized hardware design  
- Production-quality control and verification practices  

The techniques used here translate directly to **custom silicon**, **embedded acceleration**, and **mission-critical hardware systems**.
