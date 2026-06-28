// ============================================================================
// Quantos entitlements — single source of truth for what each plan unlocks.
// Used by the frontend (to gate UI) AND Netlify Functions (to enforce limits).
//
// Billing is STUBBED for now: prices/limits live here, Stripe price IDs come
// from env when wired. All three modules (Inventory, Checkout, Reports) are
// included on every paid tier — tiers differ only by item/asset/user caps.
// ============================================================================

const UNLIMITED = 1_000_000; // sentinel for "unlimited" (Enterprise)

/**
 * Plan definitions. `priceEnvKeys` name the env vars that hold the live Stripe
 * price IDs (kept out of code so the same config works across test/live modes).
 */
export const PLANS = Object.freeze({
  starter: {
    label: 'Starter',
    priceMonthly: 49,
    priceAnnual: 490, // 2 months free
    limits: { items: 200, assets: 50, users: 5 },
    priceEnvKeys: { monthly: 'STRIPE_PRICE_STARTER_MONTHLY', annual: 'STRIPE_PRICE_STARTER_ANNUAL' },
  },
  pro: {
    label: 'Pro',
    priceMonthly: 99,
    priceAnnual: 990,
    limits: { items: 1000, assets: 250, users: 25 },
    priceEnvKeys: { monthly: 'STRIPE_PRICE_PRO_MONTHLY', annual: 'STRIPE_PRICE_PRO_ANNUAL' },
  },
  enterprise: {
    label: 'Enterprise',
    priceMonthly: 199,
    priceAnnual: 1990,
    limits: { items: UNLIMITED, assets: UNLIMITED, users: UNLIMITED },
    priceEnvKeys: { monthly: 'STRIPE_PRICE_ENTERPRISE_MONTHLY', annual: 'STRIPE_PRICE_ENTERPRISE_ANNUAL' },
  },
});

export function planFor(account) {
  return PLANS[account?.plan] || PLANS.starter;
}

/** True when the account is below the cap for `kind` ('items'|'assets'|'users'). */
export function canAdd(account, kind, currentCount) {
  return currentCount < planFor(account).limits[kind];
}

/** A subscription is usable while trialing or active; not when past_due/canceled. */
export function isActive(account) {
  return account?.status === 'trialing' || account?.status === 'active';
}

export { UNLIMITED };
