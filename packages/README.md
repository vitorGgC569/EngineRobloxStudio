# Package boundaries

The current MVP implementation lives in `rqe/` to stay runnable without a package manager. These boundaries are the intended extraction points for the production monorepo:

- `orchestrator`: contract scheduling and affected-test selection;
- `validator-core`: evidence and probe interfaces;
- `roblox-adapter`: Studio MCP/Open Cloud integration;
- `scenarios`: gameplay scenario DSL;
- `evidence`: durable run storage;
- `scoring`: release policy and regression comparison.

