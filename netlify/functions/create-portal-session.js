// Open the Stripe Customer Portal for an account (manage/cancel subscription).
// Caller must be an OWNER of the account.

const Stripe = require('stripe');
const { createClient } = require('@supabase/supabase-js');
const { CORS, getUser, hasAccountRole } = require('./lib/auth');

exports.handler = async (event) => {
  if (event.httpMethod === 'OPTIONS') return { statusCode: 200, headers: CORS, body: '' };
  if (event.httpMethod !== 'POST') {
    return { statusCode: 405, headers: CORS, body: JSON.stringify({ error: 'Method not allowed' }) };
  }
  // Lazy-init after the config guard (see create-checkout-session for why).
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

    const { accountId } = JSON.parse(event.body || '{}');
    if (!accountId) {
      return { statusCode: 400, headers: CORS, body: JSON.stringify({ error: 'accountId is required' }) };
    }

    const isOwner = await hasAccountRole(supabase, accountId, user.id, ['owner']);
    if (!isOwner) {
      return { statusCode: 403, headers: CORS, body: JSON.stringify({ error: 'Owner role required' }) };
    }

    const { data: account, error: acctErr } = await supabase
      .from('accounts')
      .select('stripe_customer_id')
      .eq('id', accountId)
      .single();
    if (acctErr) {
      return { statusCode: 500, headers: CORS, body: JSON.stringify({ error: `Couldn't load the account: ${acctErr.message}` }) };
    }
    if (!account?.stripe_customer_id) {
      return { statusCode: 400, headers: CORS, body: JSON.stringify({ error: 'No billing customer for this account' }) };
    }

    const siteUrl = process.env.URL || process.env.APP_URL || 'http://localhost:8888';
    const session = await stripe.billingPortal.sessions.create({
      customer: account.stripe_customer_id,
      return_url: `${siteUrl}/app?billing=done`,
    });

    return { statusCode: 200, headers: CORS, body: JSON.stringify({ url: session.url }) };
  } catch (error) {
    console.error('create-portal-session error:', error);
    return { statusCode: 500, headers: CORS, body: JSON.stringify({ error: error.message }) };
  }
};
