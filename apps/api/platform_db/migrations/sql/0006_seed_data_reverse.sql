-- Reverse of 0006_seed_data: remove exactly the seeded rows, keyed by their
-- natural keys. Rows added at runtime (other slugs/keys) are untouched.

DELETE FROM feature_flags WHERE key IN (
    'telehealth_enabled',
    'semantic_search_enabled',
    'barber_vertical_enabled',
    'mechanic_vertical_enabled',
    'family_accounts_enabled',
    'ai_appointment_brief_enabled',
    'paystack_enabled',
    'stripe_enabled'
);

DELETE FROM service_categories WHERE slug IN ('medical', 'barber', 'mechanic');
