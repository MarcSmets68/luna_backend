# ADR-0002: Twee repos, één GitHub Project

- **Status**: aanvaard
- **Datum**: 2026-11-18

## Context

Backend (ABL/PASOE, self-hosted Windows-runner) en frontend (Next.js, GitHub-hosted runner +
Vercel) hebben een totaal verschillende toolchain en CI. Het werk wordt uitgevoerd door één
ontwikkelaar met AI-agents (Claude Code, Devin).

## Besluit

- Repos blijven gescheiden: `MarcSmets68/luna_backend` en `MarcSmets68/luna_frontend`.
- Eén user-level GitHub Project **Luna ERP** bundelt issues uit beide repos.
- Projectbrede documentatie staat in `luna_backend/docs/`.
- Labels en issue/PR-templates zijn identiek in beide repos (`scripts/github/`).
- Branches: `feature/*` → `development` → `main` in beide repos.
- Feature over beide lagen: backend-PR eerst mergen, frontend-PR verwijst ernaar.
- Agent-instructies in `AGENTS.md` per repo; `CLAUDE.md` importeert `AGENTS.md`.

## Gevolgen

- Geen atomaire PR over beide lagen; het contract (Bruno) moet eerst vastliggen.
- Labels/templates bij wijziging in beide repos synchroon houden (script).
