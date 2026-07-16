# Agent implementation

This directory contains the Windows session hooks, recorder, image setup script, configuration template, and runtime publisher used by the project.

Start with the repository-level documentation:

- [Project overview and configuration](../README.md)
- [Complete deployment walkthrough](./REPRODUCE.md)

Local environment setup:

```bash
cp .env.example .env
# Edit .env, then render and validate the runtime configuration.
./upload-agent-scripts.sh --render-only
```

Do not commit `.env` or `config.runtime.json`.
