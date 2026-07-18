-- Seed data: service_categories + feature_flags.
-- Canonical values: plans/veridian_schema.sql "SEED DATA" blocks.
--
-- NOT verbatim, deliberately. The canonical DDL gives these tables DB-level
-- defaults (id gen_random_uuid(), created_at/updated_at NOW()), but the
-- Django-generated tables manage id / timestamps / metadata at the
-- APPLICATION level (uuid4, auto_now_add/auto_now, default=dict) with no
-- database default — a bare INSERT omitting them violates NOT NULL. So the
-- INSERTs supply those columns explicitly. ON CONFLICT DO NOTHING keeps the
-- migration safe on a database where the rows already exist (e.g. seeded
-- out-of-band); the VALUES here are the canonical initial state, not an
-- upsert — later runtime edits to these rows are never clobbered.

INSERT INTO service_categories
    (id, slug, display_name, description, is_active, sort_order, created_at, updated_at)
VALUES
    (gen_random_uuid(), 'medical',   'Medical',   'Doctor and specialist consultations', TRUE,  1, NOW(), NOW()),
    (gen_random_uuid(), 'barber',    'Barber',    'Haircuts and grooming services',      FALSE, 2, NOW(), NOW()),
    (gen_random_uuid(), 'mechanic',  'Mechanic',  'Automobile repair and servicing',     FALSE, 3, NOW(), NOW())
ON CONFLICT (slug) DO NOTHING;

INSERT INTO feature_flags
    (id, key, description, is_enabled, rollout_pct, metadata, created_at, updated_at)
VALUES
    (gen_random_uuid(), 'telehealth_enabled',           'Enable telehealth video consultations',       TRUE,  100, '{}'::jsonb, NOW(), NOW()),
    (gen_random_uuid(), 'semantic_search_enabled',      'Enable embedding-based semantic search',      FALSE, 0,   '{}'::jsonb, NOW(), NOW()),
    (gen_random_uuid(), 'barber_vertical_enabled',      'Enable barber booking vertical',              FALSE, 0,   '{}'::jsonb, NOW(), NOW()),
    (gen_random_uuid(), 'mechanic_vertical_enabled',    'Enable mechanic booking vertical',            FALSE, 0,   '{}'::jsonb, NOW(), NOW()),
    (gen_random_uuid(), 'family_accounts_enabled',      'Enable family/dependent account management',  FALSE, 0,   '{}'::jsonb, NOW(), NOW()),
    (gen_random_uuid(), 'ai_appointment_brief_enabled', 'Enable AI pre-appointment brief for doctors', FALSE, 0,   '{}'::jsonb, NOW(), NOW()),
    (gen_random_uuid(), 'paystack_enabled',             'Enable Paystack payment provider',            TRUE,  100, '{}'::jsonb, NOW(), NOW()),
    (gen_random_uuid(), 'stripe_enabled',               'Enable Stripe payment provider',              FALSE, 0,   '{}'::jsonb, NOW(), NOW())
ON CONFLICT (key) DO NOTHING;
