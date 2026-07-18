# ADR-0001 — Bridging Django-issued JWTs to Supabase RLS (`auth.uid()`)

- **Status:** Accepted (2026-07-01). Owner approved Option A (Django-as-third-party-issuer). Consequences folded into `veridian_schema.sql` (hardened RLS + GRANT/REVOKE).
- **Date:** 2026-07-01
- **Deciders:** Lead engineer + project owner
- **Related:** `plans/veridian_schema.sql` (RLS), `plans/veridian-threat-model.md` Appendix A, `plans/veridian-offline-sync.md`, ADR-0003

## Context

Authentication is **Django SimpleJWT signing RS256** with the platform's own keypair
(`veridian-prompt_.md` Phase 1 step 9; threat-model E-3). Authorization at the database
is **Supabase Row Level Security**, and every policy in `veridian_schema.sql` is written as
`auth.uid() = <user column>`.

`auth.uid()` returns the `sub` claim of whatever JWT Supabase **accepts as valid**, and
Supabase/PostgREST sets the active Postgres role from the token's `role` claim. A Django
token is not, by default, a token Supabase trusts: Supabase validates tokens against its own
signing keys, not Django's. So today, a Flutter request carrying a Django JWT would reach
Supabase as the `anon` role and `auth.uid()` would be NULL.

This matters because the offline-first mobile client, Supabase Realtime, and every
authenticated direct-read in threat-model Appendix A depend on Supabase recognising the
caller as the correct user. **Unresolved, this either breaks those features or tempts us to
weaken RLS — which would blow the PHI isolation the whole threat model rests on.**

Verified against current Supabase docs (2026-07-01):
- Third-party auth requires **asymmetrically signed JWTs** exposed via an **OIDC/JWKS
  discovery URL**, with a `kid` header identifying the signing key. Django's RS256 already
  produces asymmetric tokens — this is a clean fit.
- `auth.uid()` = the `sub` claim; the DB role is taken from the `role` claim (payload example
  shows `"role": "authenticated"`).

## Decision drivers

1. Do not run two identity systems. One source of truth for "who is this user."
2. RLS must remain a real, independent enforcement layer (defence-in-depth per threat model).
3. Token minting stays in Django (OTP via Termii, KYC, role management already live there).
4. Minimise secret sprawl and rotation complexity.

## Options considered

### Option A — Register Django as a Supabase **third-party auth issuer** (JWKS) — *recommended*

Django exposes its RS256 **public** key at a JWKS endpoint
(`/.well-known/jwks.json`). Supabase is configured to trust that issuer. The Django access
token is minted with the claims Supabase needs, and Flutter/web hand that same token to the
Supabase client.

Required token shape (minted by Django for the client-facing access token):
```
header:  { "alg": "RS256", "kid": "<current signing key id>", "typ": "JWT" }
payload: {
  "iss":  "https://api.veridian.app",     // must match the registered issuer
  "sub":  "<public.users.id UUID>",         // becomes auth.uid()
  "role": "authenticated",                  // sets the Postgres role — NEVER 'service_role'
  "aud":  "authenticated",
  "exp":  <15 min>, "iat": <now>,
  "user_role": "patient|doctor|clinic_admin|platform_admin"  // app role, distinct from DB role
}
```
- `role` is the **Postgres** role and is always `authenticated` for end users. The Veridian
  application role (patient/doctor/admin) is a **separate** claim (`user_role`) and is
  re-read from the DB server-side anyway (threat-model E-1/E-3). Never conflate the two.
- Django keeps signing everything; Supabase only ever sees the **public** key. No shared
  secret. Key rotation = publish new key in JWKS with a new `kid` (dual-key window), which
  Supabase picks up automatically.

**Pros:** one identity system; no shared secret; RS256 keypair already planned; rotation is
clean; RLS stays honest. **Cons:** the client-facing access token becomes a "Supabase-shaped"
token, so we must be disciplined that `sub`/`role`/`aud` are exactly right and that the app
role never leaks into the `role` claim.

### Option B — Mint a **separate** short-lived Supabase token alongside the Django token

Django issues its normal API token **and** a second token (HS256 with the Supabase JWT
secret, or RS256) purely for the Supabase client.

**Pros:** keeps the Django API token shape unconstrained. **Cons:** two tokens to mint,
refresh, store, and revoke on every client; HS256 variant means sharing Supabase's JWT
secret into Django (a secret we'd rather not hold); more moving parts in the offline client's
refresh logic. Rejected unless Option A hits a blocker.

### Option C — Adopt Supabase Auth (GoTrue) as the IdP

Let Supabase issue tokens; Django verifies them.

**Cons:** conflicts with the whole planned auth design (Django-issued JWTs, Termii OTP, custom
KYC/role flows, refresh-token blocklist, WebAuthn for admins). Large rewrite of Phase 1 auth
for no net benefit. Rejected.

## Decision (recommended)

Adopt **Option A**. Django is the single issuer; it publishes a JWKS endpoint; Supabase is
registered to trust it; the client-facing access token carries `sub = users.id`,
`role = "authenticated"`, `aud = "authenticated"`, and a **separate** `user_role` claim for
app-level role. Service-to-service DB access from Django continues to use the Supabase
**service role key** (which bypasses RLS) — never the user token.

### RLS hardening to apply at the same time (from Supabase security review)

The current policies work but have gaps that this ADR should fix in the same migration:
1. Add explicit **`TO authenticated` / `TO anon`** to every policy. `USING (auth.uid() = …)`
   without a `TO` clause is looser than intended, and `TO authenticated` **alone** is BOLA —
   always pair the role with the ownership predicate.
2. Every `FOR ALL` / `FOR UPDATE` policy needs a **`WITH CHECK`**, not just `USING`. Several
   current policies (e.g. `patient_profile_own`, `timeline_patient_own`, `consent_patient_own`)
   are `FOR ALL USING (...)` with no `WITH CHECK`, which lets a row be **reassigned to another
   user** on UPDATE/INSERT. Add matching `WITH CHECK`.
3. Never authorize on user-editable metadata. The app role lives in `public.users.role`
   (server-set) and is re-read server-side; it must never be trusted from a token claim the
   user could influence.
4. `v_appointments_safe` must be a **definer-style** view with the patient/doctor ownership
   predicates embedded in its `WHERE` clause, plus `security_barrier = true`. Ensure base-table
   `SELECT` is revoked from `authenticated` and only the view is granted (threat-model I-4b).
   *(Corrected 2026-07-17: this item originally endorsed `security_invoker = true`, which
   contradicts the base-table REVOKE — an invoker view runs with the caller's privileges, so
   the view was unreadable by exactly the clients it exists for. See ADR-0007 addendum.)*

## Consequences

- Phase 0 must stand up the JWKS endpoint and the Supabase third-party-auth registration
  before any authenticated direct-read or Realtime feature is built.
- The direct-read RLS test suite (`test_rls_direct_read.py`) becomes the **acceptance gate**
  for this ADR: `mint_jwt(user)` must produce a token that Supabase accepts and that yields
  the correct `auth.uid()`. That test currently assumes this works — it must be made real
  first.
- Token TTL is 15 min for the client token; the Supabase client must refresh via Django's
  refresh-rotation flow, not GoTrue.

## Open questions for the owner

1. **Are you comfortable making the client-facing access token "Supabase-shaped" (Option A)?**
   The alternative (Option B, two tokens) is more code in the offline client. I recommend A.
2. **Which tables are actually read directly from Supabase?** This ADR's blast radius depends
   on it — see ADR-0003. If we drop authenticated PHI direct-reads (my recommendation), the
   auth bridge only needs to cover non-PHI tables, which lowers risk substantially.
