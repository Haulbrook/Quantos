// Stripe webhook -> sync subscription state onto the accounts row.
// Sets plan, status, stripe_subscription_id, and the plan's item/asset/user caps.
// Matches the account by metadata.accountId, falling back to stripe_customer_id.

const Stripe = require('stripe');
const { createClient } = require('@supabase/supabase-js');
const { limitsFor, planFromPriceId } = require('./lib/plans');

const STATUS_MAP = {
  active: 'active', trialing: 'trialing', past_due: 'past_due', unpaid: 'past_due',
  canceled: 'canceled', incomplete: 'trialing', incomplete_expired: 'canceled', paused: 'canceled',
};

// Map a plan name onto the accounts caps columns.
function capFields(plan) {
  const l = limitsFor(plan);
  return { item_limit: l.items, asset_limit: l.assets, user_limit: l.users };
}

// Update the matched account, THROWING on error so the handler's catch can roll
// back the idempotency marker and let Stripe retry — instead of silently losing
// the write while the event is recorded as processed.
async function updateAccount(supabase, match, fields) {
  const q = supabase.from('accounts').update(fields);
  const { error } = await (match.accountId
    ? q.eq('id', match.accountId)
    : q.eq('stripe_customer_id', match.customerId));
  if (error) throw new Error(`accounts update failed: ${error.message}`);
}

exports.handler = async (event) => {
  if (event.httpMethod !== 'POST') {
    return { statusCode: 405, body: JSON.stringify({ error: 'Method not allowed' }) };
  }
  if (!process.env.STRIPE_SECRET_KEY || !process.env.STRIPE_WEBHOOK_SECRET || !process.env.SUPABASE_SERVICE_ROLE_KEY || !process.env.SUPABASE_URL) {
    return { statusCode: 503, body: JSON.stringify({ error: 'Billing is not configured yet' }) };
  }
  const stripe = Stripe(process.env.STRIPE_SECRET_KEY);
  const supabase = createClient(process.env.SUPABASE_URL, process.env.SUPABASE_SERVICE_ROLE_KEY);

  const sig = event.headers['stripe-signature'];
  // Netlify may base64-encode the body; Stripe needs the exact raw bytes.
  const rawBody = event.isBase64Encoded ? Buffer.from(event.body, 'base64') : event.body;
  let evt;
  try {
    evt = stripe.webhooks.constructEvent(rawBody, sig, process.env.STRIPE_WEBHOOK_SECRET);
  } catch (err) {
    console.error('Webhook signature verification failed:', err.message);
    return { statusCode: 400, body: JSON.stringify({ error: `Webhook Error: ${err.message}` }) };
  }

  // Idempotency: claim the event id first so concurrent retries/replays don't
  // double-process. If processing then FAILS, we DELETE the marker (catch block)
  // so Stripe's retry reprocesses instead of being swallowed as a duplicate.
  const seen = await supabase.from('stripe_events').insert({ id: evt.id, type: evt.type });
  if (seen.error && seen.error.code === '23505') {
    return { statusCode: 200, body: JSON.stringify({ received: true, duplicate: true }) };
  }

  try {
    switch (evt.type) {
      case 'checkout.session.completed': {
        const session = evt.data.object;
        if (!session.subscription) break;
        const sub = await stripe.subscriptions.retrieve(session.subscription);
        const priceId = sub.items?.data?.[0]?.price?.id;
        const plan = session.metadata?.plan || planFromPriceId(priceId);
        const fields = { stripe_subscription_id: sub.id, status: 'active' };
        if (plan) { fields.plan = plan; Object.assign(fields, capFields(plan)); }
        else console.warn('checkout.session.completed: unmatched priceId, leaving plan/caps unchanged', priceId);
        await updateAccount(supabase, { accountId: session.metadata?.accountId, customerId: session.customer }, fields);
        break;
      }

      case 'customer.subscription.created':
      case 'customer.subscription.updated': {
        const sub = evt.data.object;
        const priceId = sub.items?.data?.[0]?.price?.id;
        const status = STATUS_MAP[sub.status] || 'past_due';
        const plan = sub.metadata?.plan || planFromPriceId(priceId);
        const fields = { stripe_subscription_id: sub.id, status };
        if (plan) { fields.plan = plan; Object.assign(fields, capFields(plan)); }
        else console.warn(`${evt.type}: unmatched priceId, leaving plan/caps unchanged`, priceId);
        await updateAccount(supabase, { accountId: sub.metadata?.accountId, customerId: sub.customer }, fields);
        break;
      }

      case 'customer.subscription.deleted': {
        const sub = evt.data.object;
        await updateAccount(supabase, { accountId: sub.metadata?.accountId, customerId: sub.customer }, { status: 'canceled' });
        break;
      }

      case 'invoice.payment_failed': {
        const inv = evt.data.object;
        await updateAccount(supabase, { customerId: inv.customer }, { status: 'past_due' });
        break;
      }

      case 'invoice.payment_succeeded': {
        const inv = evt.data.object;
        // Reactivate only if currently past_due.
        const { error } = await supabase.from('accounts').update({ status: 'active' })
          .eq('stripe_customer_id', inv.customer).eq('status', 'past_due');
        if (error) throw new Error(`invoice.payment_succeeded update failed: ${error.message}`);
        break;
      }

      default:
        console.log(`Unhandled event type: ${evt.type}`);
    }

    return { statusCode: 200, body: JSON.stringify({ received: true }) };
  } catch (error) {
    console.error('Webhook handler error:', error);
    // Roll back the idempotency marker so Stripe's retry reprocesses this event.
    await supabase.from('stripe_events').delete().eq('id', evt.id);
    return { statusCode: 500, body: JSON.stringify({ error: error.message }) };
  }
};
