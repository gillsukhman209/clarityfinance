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
        user_id text,
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
        user_id text,
        device_id text references devices(device_id) on delete set null,
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
      create table if not exists accounts (
        account_id text primary key,
        user_id text,
        item_id text not null references plaid_items(item_id) on delete cascade,
        institution_name text,
        name text not null,
        mask text,
        kind text not null default 'manual',
        current_balance numeric not null default 0,
        available_balance numeric,
        currency_code text not null default 'USD',
        raw jsonb not null default '{}'::jsonb,
        updated_at timestamptz not null default now()
      )
    `;

    await db`
      create table if not exists credit_card_liabilities (
        account_id text primary key,
        user_id text,
        item_id text not null references plaid_items(item_id) on delete cascade,
        minimum_payment_amount numeric,
        next_payment_due_date date,
        last_payment_amount numeric,
        last_payment_date date,
        last_statement_balance numeric,
        last_statement_issue_date date,
        is_overdue boolean,
        apr_percentage numeric,
        raw jsonb not null default '{}'::jsonb,
        updated_at timestamptz not null default now()
      )
    `;

    await db`
      create table if not exists removed_accounts (
        user_id text not null,
        account_id text not null,
        item_id text,
        removed_at timestamptz not null default now(),
        primary key (user_id, account_id)
      )
    `;

    await db`
      create table if not exists notification_events (
        id bigserial primary key,
        user_id text,
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

    await db`alter table devices add column if not exists user_id text`;
    await db`alter table plaid_items add column if not exists user_id text`;
    await db`alter table plaid_items alter column device_id drop not null`;
    await db`alter table accounts add column if not exists user_id text`;
    await db`alter table notification_events add column if not exists user_id text`;
    await db`create index if not exists transactions_item_date_idx on transactions(item_id, date desc)`;
    await db`create index if not exists transactions_account_date_idx on transactions(account_id, date desc)`;
    await db`create index if not exists accounts_user_idx on accounts(user_id)`;
    await db`create index if not exists accounts_item_idx on accounts(item_id)`;
    await db`create index if not exists credit_card_liabilities_user_idx on credit_card_liabilities(user_id)`;
    await db`create index if not exists credit_card_liabilities_item_idx on credit_card_liabilities(item_id)`;
    await db`create index if not exists removed_accounts_user_idx on removed_accounts(user_id)`;
    await db`create index if not exists devices_user_idx on devices(user_id)`;
    await db`create index if not exists plaid_items_user_idx on plaid_items(user_id)`;
    await db`create index if not exists notification_events_device_created_idx on notification_events(device_id, created_at desc)`;
    await db`create index if not exists notification_events_dedupe_idx on notification_events(device_id, event_type, merchant_key, created_at desc)`;
  })();

  return schemaReady;
}

module.exports = {
  ensureSchema,
  sql
};
