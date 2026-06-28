// Shared plan helpers for Netlify Functions (CommonJS).
// SINGLE source of truth for plan -> caps + Stripe price env vars on the server.
// The Stripe webhook writes these caps onto the account row, where DB triggers
// (migration 0009) enforce them; the frontend's PLANS object is display copy
// only. (Files under netlify/functions/lib are bundled into each function, not
// exposed as endpoints themselves.)

const UNLIMITED = 1_000_000;

// plan -> per-tier caps. Written onto the accounts row by the Stripe webhook.
const LIMITS = {
  starter:    { items: 200,       assets: 50,        users: 5 },
  pro:        { items: 1000,      assets: 250,       users: 25 },
  enterprise: { items: UNLIMITED, assets: UNLIMITED, users: UNLIMITED },
};

// plan + interval -> the env var holding that Stripe price ID
const PRICE_ENV = {
  starter:    { monthly: 'STRIPE_PRICE_STARTER_MONTHLY',    annual: 'STRIPE_PRICE_STARTER_ANNUAL' },
  pro:        { monthly: 'STRIPE_PRICE_PRO_MONTHLY',        annual: 'STRIPE_PRICE_PRO_ANNUAL' },
  enterprise: { monthly: 'STRIPE_PRICE_ENTERPRISE_MONTHLY', annual: 'STRIPE_PRICE_ENTERPRISE_ANNUAL' },
};

function limitsFor(plan) {
  return LIMITS[plan] || LIMITS.starter;
}

function priceIdFor(plan, interval) {
  const key = PRICE_ENV[plan]?.[interval];
  return key ? process.env[key] : undefined;
}

// reverse-map a Stripe price ID back to our plan name, using the env values.
// Returns null on no match so the caller can fail CLOSED (skip the plan write)
// rather than silently granting the most-entitling plan on Stripe data drift.
function planFromPriceId(priceId) {
  for (const [plan, intervals] of Object.entries(PRICE_ENV)) {
    for (const envKey of Object.values(intervals)) {
      if (priceId && process.env[envKey] === priceId) return plan;
    }
  }
  return null;
}

module.exports = { UNLIMITED, limitsFor, priceIdFor, planFromPriceId };
