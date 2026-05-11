const postgres = require("postgres");

let client;
let schemaReady;

function databaseURL() {
  const candidates = [
    process.env.POSTGRES_URL,
    process.env.POSTGRES_URL_NON_POOLING,
    process.env.POSTGRES_PRISMA_URL,
    process.env.SUPABASE_DB_URL,
    process.env.DATABASE_URL
  ];

  const validURL = candidates.find((value) => /^postgres(ql)?:\/\//.test(value || ""));
  if (!validURL) {
    throw new Error("A Postgres connection URL is required. Set DATABASE_URL or POSTGRES_URL to a postgres:// URL.");
  }

  return validURL;
}

function sql() {
  if (!client) {
    client = postgres(databaseURL(), {
      max: 3,
      idle_timeout: 20,
      connect_timeout: 10
    });
  }

  return client;
}

async function ensureSchema() {
  if (schemaReady) {
    return schemaReady;
  }

  const db = sql();
  schemaReady = (async () => {
    await db`
      create table if not exists devices (
        device_id text primary key,
        apns_token text not null,
        platform text not null,
        enabled boolean not null default true,
        tone text not null default 'funny',
        privacy text not null default 'merchant_amount',
        created_at timestamptz not null default now(),
        updated_at timestamptz not null default now()
      )
    `;

    await db`
      create table if not exists plaid_items (
        item_id text primary key,
        device_id text not null references devices(device_id) on delete cascade,
        access_token_encrypted text not null,
        environment text not null,
        institution_id text,
        institution_name text,
        cursor text,
        created_at timestamptz not null default now(),
        updated_at timestamptz not null default now()
      )
    `;

    await db`
      create table if not exists transactions (
        transaction_id text primary key,
        item_id text not null references plaid_items(item_id) on delete cascade,
        account_id text,
        merchant_name text not null,
        original_name text not null,
        amount numeric not null,
        date date not null,
        category text not null default 'other',
        pending boolean not null default false,
        source text not null default 'plaid',
        raw jsonb not null default '{}'::jsonb,
        updated_at timestamptz not null default now()
      )
    `;

    await db`
      create table if not exists notification_events (
        id bigserial primary key,
        device_id text not null references devices(device_id) on delete cascade,
        item_id text,
        event_type text not null,
        merchant_key text,
        transaction_id text,
        title text,
        body text,
        status text not null,
        reason text,
        created_at timestamptz not null default now()
      )
    `;

    await db`create index if not exists transactions_item_date_idx on transactions(item_id, date desc)`;
    await db`create index if not exists notification_events_device_created_idx on notification_events(device_id, created_at desc)`;
    await db`create index if not exists notification_events_dedupe_idx on notification_events(device_id, event_type, merchant_key, created_at desc)`;
  })();

  return schemaReady;
}

module.exports = {
  ensureSchema,
  sql
};
