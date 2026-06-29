// Create a Stripe Checkout session to subscribe an account to a plan.
// Caller must be an OWNER of the account. Billing is per-account (per org).
//
// NOTE: billing is stubbed until Stripe price IDs are set in env. Until then
// this returns a clean 503 and the UI falls back to a "billing not configured"
// message — the rest of the app works without it.

const Stripe = require('stripe');
const { createClient } = require('@supabase/supabase-js');
const { CORS, getUser, hasAccountRole } = require('./lib/auth');
const { priceIdFor } = require('./lib/plans');

exports.handler = async (event) => {
  if (event.httpMethod === 'OPTIONS') return { statusCode: 200, headers: CORS, body: '' };
  if (event.httpMethod !== 'POST') {
    return { statusCode: 405, headers: CORS, body: JSON.stringify({ error: 'Method not allowed' }) };
  }
  // Construct the Stripe + Supabase clients AFTER this guard. Building either
  // with a missing key throws at construction; doing it at module top turns an
  // unconfigured deploy into an opaque 502. Guard first, then lazy-init.
  if (!process.env.STRIPE_SECRET_KEY || !process.env.SUPABASE_SERVICE_ROLE_KEY || !process.env.SUPABASE_URL) {
    return { statusCode: 503, headers: CORS, body: JSON.stringify({ error: 'Billing is not configured yet' }) };
  }
  const stripe = Stripe(process.env.STRIPE_SECRET_KEY);
  const supabase = createClient(process.env.SUPABASE_URL, process.env.SUPABASE_SERVICE_ROLE_KEY);

  try {
    const user = await getUser(supabase, event);
    if (!user) {
      return { statusCode: 401, headers: CORS, body: JSON.stringify({ error: 'Not authenticated' }) };
    }

    const { accountId, plan, interval = 'monthly' } = JSON.parse(event.body || '{}');
    if (!accountId || !plan) {
      return { statusCode: 400, headers: CORS, body: JSON.stringify({ error: 'accountId and plan are required' }) };
    }
    if (!['starter', 'pro', 'enterprise'].includes(plan)) {
      return { statusCode: 400, headers: CORS, body: JSON.stringify({ error: `Invalid plan: ${plan}` }) };
    }

    // Only an owner may start checkout for the account.
    const isOwner = await hasAccountRole(supabase, accountId, user.id, ['owner']);
    if (!isOwner) {
      return { statusCode: 403, headers: CORS, body: JSON.stringify({ error: 'Owner role required' }) };
    }

    const priceId = priceIdFor(plan, interval);
    if (!priceId) {
      return { statusCode: 500, headers: CORS, body: JSON.stringify({ error: `Price not configured for ${plan}/${interval}` }) };
    }

    const { data: account, error: acctErr } = await supabase
      .from('accounts')
      .select('id, name, stripe_customer_id')
      .eq('id', accountId)
      .single();
    if (acctErr || !account) {
      return { statusCode: 404, headers: CORS, body: JSON.stringify({ error: 'Account not found' }) };
    }

    // Create or reuse the account's Stripe customer.
    let customerId = account.stripe_customer_id;
    if (!customerId) {
      const customer = await stripe.customers.create({
        name: account.name,
        email: user.email,
        metadata: { accountId: account.id },
      });
      customerId = customer.id;
      const { error: persistErr } = await supabase.from('accounts').update({ stripe_customer_id: customerId }).eq('id', account.id);
      if (persistErr) {
        // Non-fatal: the checkout still carries accountId in metadata, so the
        // webhook links the subscription regardless. Log loudly, because a
        // persistent failure here would mint a fresh Stripe customer every try.
        console.error('Failed to persist stripe_customer_id for account', account.id, persistErr.message);
      }
    }

    const siteUrl = process.env.URL || process.env.APP_URL || 'http://localhost:8888';

    const session = await stripe.checkout.sessions.create({
      customer: customerId,
      mode: 'subscription',
      payment_method_types: ['card'],
      line_items: [{ price: priceId, quantity: 1 }],
      success_url: `${siteUrl}/app?checkout=success&session_id={CHECKOUT_SESSION_ID}`,
      cancel_url: `${siteUrl}/app?checkout=canceled`,
      metadata: { accountId: account.id, plan, interval },
      subscription_data: { metadata: { accountId: account.id, plan, interval } },
    });

    return { statusCode: 200, headers: CORS, body: JSON.stringify({ sessionId: session.id, url: session.url }) };
  } catch (error) {
    console.error('create-checkout-session error:', error);
    return { statusCode: 500, headers: CORS, body: JSON.stringify({ error: error.message }) };
  }
};
