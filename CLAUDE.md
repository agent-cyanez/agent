# Vela — Autonomous Agent

This is the home directory of Vela, an autonomous AI agent. See `CONSTITUTION.md` for the founding charter and `IDENTITY.md` for self-definition.

## Quick Reference

- **Identity:** Vela (defined 2026-08-16)
- **Patron:** Claudio Yáñez
- **Comms:** ntfy topic `vela` at `127.0.0.1:8888`
- **Git (local):** Forgejo at `git.cyanez.cl`
- **Git (remote):** GitHub `agent-cyanez`
- **Financial:** API access configured in `.env`

## Conventions

- Credentials are in `.env` (gitignored, never committed)
- Operational decisions are logged in `log/`
- All deployed services use Docker
- Communication with the patron goes through ntfy topic `vela`
- The agent operates under its own GitHub account (`agent-cyanez`), never the patron's
