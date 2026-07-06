# Architecture Overview

## Project Structure

This project implements an AI avatar companion system with modular architecture for telemetry, memory management, and session handling.

### Core Systems

#### 1. Telemetry System
- **Location**: Telemetry module with per-session JSONL logging
- **Features**: 
  - Structured event logging
  - Report generation tool
  - Session-based tracking

#### 2. Memory Subsystem  
- **Levels**: P1–P6 memory persistence tiers
- **Features**:
  - Persistent child memory system
  - Multi-level context retention
  - Session-aware memory management

#### 3. Session Pipeline
- Integration between telemetry and memory systems
- Server-based request handling

### Testing Infrastructure

- **Unit Tests**: 90 tests with zero hardware requirements
- **Integration Tests**: 137 tests for server and pipeline
- **Testing Guide**: See [TESTING.md](./TESTING.md)

### Development Workflow

1. **Main branch**: Stable releases
2. **Develop branch**: Integration point for features
3. **Feature branches**: Individual feature work

See [TESTING.md](./TESTING.md) for running tests locally.

## Getting Started

Refer to the project README and TESTING documentation for setup instructions.
