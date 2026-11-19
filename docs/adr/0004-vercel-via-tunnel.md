# ADR-0004: Vercel-frontend bereikt PASOE via een tunnel

- **Status**: voorgesteld
- **Datum**: 2026-11-18

## Context

De frontend wordt via GitHub Actions naar Vercel gedeployed (preview + productie). PASOE draait
lokaal (MarcTest 8080) en is niet publiek bereikbaar.

## Besluit

- Een tunnel (voorkeur: Cloudflare Tunnel met Cloudflare Access ervoor) maakt MarcTest bereikbaar.
- Vercel krijgt `API_BASE_URL` naar de tunnel-URL.
- **De tunnel gaat pas open nadat**:
  1. wachtwoorden gehasht zijn (`docs/wachtwoord-hashing-voorstel.md`);
  2. `AUTH_ENFORCE=true` op de instantie;
  3. alle handlers via `AuthGuard` lopen (ook de NPP-handlers en Logout);
  4. `DEV_ENDPOINTS_ENABLED=false`;
  5. login-throttle actief.

## Gevolgen

- Security-werk wordt P0 vóór de Vercel-koppeling.
- Tot dan zijn Vercel-previews enkel een UI-check zonder werkende data.
