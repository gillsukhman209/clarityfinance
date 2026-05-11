const { decrypt, encrypt } = require("../_lib/crypto");
const { ensureSchema, sql } = require("../_lib/db");
const { methodNotAllowed, readJson, sendJson } = require("../_lib/http");
const {
  createHostedLinkToken,
  exchangePublicToken,
  fetchAccounts,
  getLinkToken,
  normalizePlaidTransaction,
  publicTokenMetadata,
  refreshTransactions,
  syncTransactions,
  updateItemWebhook
} = require("../_lib/plaid");
const { webhookURLForRequest } = require("../_lib/requestUrl");
const { requireSupabaseUser } = require("../_lib/supabaseAuth");

function routePath(req) {
  const url = new URL(req.url, "https://clarity.local");
  if (url.searchParams.get("route")) {
    return url.searchParams.get("route").replace(/^\/+/, "").replace(/\/+$/, "");
  }
  return url.pathname.replace(/^\/api\/plaid\/?/, "").replace(/\/+$/, "");
}

async function upsertTransactions(db, itemID, transactions) {
  for (const transaction of transactions) {
    await db`
      insert into transactions (
        transaction_id,
        item_id,
        account_id,
        merchant_name,
        original_name,
        amount,
        date,
        category,
        pending,
        source,
        raw,
        updated_at
      )
      values (
        ${transaction.transactionId},
        ${itemID},
        ${transaction.accountId},
        ${transaction.merchantName},
        ${transaction.originalName},
        ${transaction.amount},
        ${transaction.date},
        ${transaction.category},
        ${transaction.pending},
        ${transaction.source},
        ${transaction.raw},
        now()
      )
      on conflict (transaction_id)
      do update set
        account_id = excluded.account_id,
        merchant_name = excluded.merchant_name,
        original_name = excluded.original_name,
        amount = excluded.amount,
        date = excluded.date,
        category = excluded.category,
        pending = excluded.pending,
        source = excluded.source,
        raw = excluded.raw,
        updated_at = now()
    `;
  }
}

function accountKind(account) {
  if (account.type === "depository" && account.subtype === "checking") {
    return "checking";
  }
  if (account.type === "depository" && account.subtype === "savings") {
    return "savings";
  }
  if (account.type === "credit") {
    return "creditCard";
  }
  if (account.type === "investment" || account.type === "brokerage") {
    return "investment";
  }
  if (account.type === "loan") {
    return "loan";
  }
  return "manual";
}

async function upsertAccounts(db, userID, itemID, institutionName, accounts) {
  for (const account of accounts) {
    await db`
      insert into accounts (
        account_id,
        user_id,
        item_id,
        institution_name,
        name,
        mask,
        kind,
        current_balance,
        available_balance,
        currency_code,
        raw,
        updated_at
      )
      values (
        ${account.account_id},
        ${userID},
        ${itemID},
        ${institutionName || null},
        ${account.name || "Account"},
        ${account.mask || null},
        ${accountKind(account)},
        ${Number(account.balances?.current || 0)},
        ${account.balances?.available == null ? null : Number(account.balances.available)},
        ${account.balances?.iso_currency_code || account.balances?.unofficial_currency_code || "USD"},
        ${account},
        now()
      )
      on conflict (account_id)
      do update set
        user_id = excluded.user_id,
        item_id = excluded.item_id,
        institution_name = excluded.institution_name,
        name = excluded.name,
        mask = excluded.mask,
        kind = excluded.kind,
        current_balance = excluded.current_balance,
        available_balance = excluded.available_balance,
        currency_code = excluded.currency_code,
        raw = excluded.raw,
        updated_at = now()
    `;
  }
}

async function loadUserItem(db, userID, itemID) {
  const rows = await db`
    select item_id, access_token_encrypted, environment, cursor, institution_id, institution_name, created_at, updated_at
    from plaid_items
    where item_id = ${itemID}
      and user_id = ${userID}
    limit 1
  `;
  return rows[0] || null;
}

async function removedAccountIDs(db, userID) {
  const rows = await db`
    select account_id
    from removed_accounts
    where user_id = ${userID}
  `;
  return new Set(rows.map((row) => row.account_id));
}

function snapshotConnection(row) {
  return {
    id: row.item_id,
    itemID: row.item_id,
    institutionID: row.institution_id || "linked-institution",
    institutionName: row.institution_name || "Linked Bank",
    accessToken: "",
    environment: row.environment || "production",
    cursor: row.cursor || null,
    connectedAt: row.created_at,
    lastSyncedAt: row.updated_at
  };
}

function snapshotAccount(row) {
  return {
    id: row.account_id,
    institutionName: row.institution_name || "Linked Bank",
    name: row.name,
    mask: row.mask || null,
    kind: row.kind || "manual",
    currentBalance: Number(row.current_balance || 0),
    availableBalance: row.available_balance == null ? null : Number(row.available_balance),
    currencyCode: row.currency_code || "USD",
    isManual: false
  };
}

function snapshotTransaction(row) {
  return {
    id: row.transaction_id,
    accountID: row.account_id || "",
    merchantName: row.merchant_name,
    originalName: row.original_name,
    amount: Number(row.amount || 0),
    date: row.date,
    category: row.category || "other",
    pending: Boolean(row.pending),
    source: row.source || "Plaid"
  };
}

async function handleCreateLinkToken(req, res, user, body) {
  const environment = body.environment === "sandbox" ? "sandbox" : "production";
  const linkCustomizationName = String(body.link_customization_name || "").trim() || null;
  const payload = await createHostedLinkToken({
    environment,
    userID: user.id,
    linkCustomizationName,
    webhookURL: webhookURLForRequest(req)
  });
  return sendJson(res, 200, payload);
}

async function handleGetLinkToken(res, body) {
  const linkToken = String(body.link_token || "").trim();
  if (!linkToken) {
    return sendJson(res, 400, { ok: false, error: "link_token_required" });
  }

  const environment = body.environment === "sandbox" ? "sandbox" : "production";
  const payload = await getLinkToken({ environment, linkToken });
  return sendJson(res, 200, payload);
}

async function handleExchangePublicToken(req, res, user, body) {
  const publicToken = String(body.public_token || "").trim();
  if (!publicToken) {
    return sendJson(res, 400, { ok: false, error: "public_token_required" });
  }

  const environment = body.environment === "sandbox" ? "sandbox" : "production";
  const exchange = await exchangePublicToken({ environment, publicToken });
  const metadata = publicTokenMetadata(body);

  await ensureSchema();
  const db = sql();
  await db`
    insert into plaid_items (
      item_id,
      user_id,
      device_id,
      access_token_encrypted,
      environment,
      institution_id,
      institution_name,
      cursor,
      updated_at
    )
    values (
      ${exchange.item_id},
      ${user.id},
      ${body.device_id || null},
      ${encrypt(exchange.access_token)},
      ${environment},
      ${metadata.institutionID},
      ${metadata.institutionName},
      null,
      now()
    )
    on conflict (item_id)
    do update set
      user_id = excluded.user_id,
      device_id = coalesce(excluded.device_id, plaid_items.device_id),
      access_token_encrypted = excluded.access_token_encrypted,
      environment = excluded.environment,
      institution_id = excluded.institution_id,
      institution_name = excluded.institution_name,
      updated_at = now()
  `;

  const webhook = await updateItemWebhook({
    accessToken: exchange.access_token,
    environment,
    webhookURL: webhookURLForRequest(req)
  });

  return sendJson(res, 200, {
    access_token: "",
    item_id: exchange.item_id,
    user_id: user.id,
    webhook
  });
}

async function handleAccounts(res, user, body) {
  const itemID = String(body.item_id || "").trim();
  if (!itemID) {
    return sendJson(res, 400, { ok: false, error: "item_id_required" });
  }

  await ensureSchema();
  const item = await loadUserItem(sql(), user.id, itemID);
  if (!item) {
    return sendJson(res, 404, { ok: false, error: "plaid_item_not_found_for_user" });
  }

  const payload = await fetchAccounts({
    accessToken: decrypt(item.access_token_encrypted),
    environment: item.environment
  });
  await upsertAccounts(sql(), user.id, itemID, item.institution_name, payload.accounts || []);
  return sendJson(res, 200, payload);
}

async function handleTransactionsSync(res, user, body) {
  const itemID = String(body.item_id || "").trim();
  if (!itemID) {
    return sendJson(res, 400, { ok: false, error: "item_id_required" });
  }

  await ensureSchema();
  const db = sql();
  const item = await loadUserItem(db, user.id, itemID);
  if (!item) {
    return sendJson(res, 404, { ok: false, error: "plaid_item_not_found_for_user" });
  }

  const sync = await syncTransactions({
    accessToken: decrypt(item.access_token_encrypted),
    environment: item.environment,
    cursor: body.cursor || item.cursor
  });
  const removedAccounts = await removedAccountIDs(db, user.id);
  const added = sync.added.filter((transaction) => !removedAccounts.has(transaction.account_id));
  const modified = sync.modified.filter((transaction) => !removedAccounts.has(transaction.account_id));
  const normalized = [...added, ...modified].map((transaction) => normalizePlaidTransaction(transaction, itemID));
  await upsertTransactions(db, itemID, normalized);
  for (const removed of sync.removed) {
    await db`delete from transactions where transaction_id = ${removed.transaction_id}`;
  }
  await db`
    update plaid_items
    set cursor = ${sync.nextCursor}, updated_at = now()
    where item_id = ${itemID}
      and user_id = ${user.id}
  `;

  return sendJson(res, 200, {
    added,
    modified,
    removed: sync.removed,
    next_cursor: sync.nextCursor,
    has_more: false
  });
}

async function handleTransactionsRefresh(res, user, body) {
  const itemID = String(body.item_id || "").trim();
  if (!itemID) {
    return sendJson(res, 400, { ok: false, error: "item_id_required" });
  }

  await ensureSchema();
  const item = await loadUserItem(sql(), user.id, itemID);
  if (!item) {
    return sendJson(res, 404, { ok: false, error: "plaid_item_not_found_for_user" });
  }

  const payload = await refreshTransactions({
    accessToken: decrypt(item.access_token_encrypted),
    environment: item.environment
  });
  return sendJson(res, 200, payload);
}

async function handleSnapshot(res, user) {
  await ensureSchema();
  const db = sql();
  const items = await db`
    select item_id, access_token_encrypted, environment, cursor, institution_id, institution_name, created_at, updated_at
    from plaid_items
    where user_id = ${user.id}
    order by created_at asc
  `;
  const removedAccounts = await removedAccountIDs(db, user.id);

  for (const item of items) {
    try {
      const payload = await fetchAccounts({
        accessToken: decrypt(item.access_token_encrypted),
        environment: item.environment
      });
      await upsertAccounts(db, user.id, item.item_id, item.institution_name, payload.accounts || []);
    } catch (error) {
      console.error("snapshot account refresh failed", item.item_id, error.message);
    }
  }

  const accounts = await db`
    select account_id, institution_name, name, mask, kind, current_balance, available_balance, currency_code
    from accounts
    where user_id = ${user.id}
    order by institution_name asc nulls last, name asc
  `;
  const transactions = await db`
    select t.transaction_id, t.account_id, t.merchant_name, t.original_name, t.amount, t.date::text as date, t.category, t.pending, t.source
    from transactions t
    join plaid_items i on i.item_id = t.item_id
    where i.user_id = ${user.id}
    order by t.date desc, t.updated_at desc
  `;

  return sendJson(res, 200, {
    ok: true,
    user_id: user.id,
    connections: items.map(snapshotConnection),
    accounts: accounts.filter((account) => !removedAccounts.has(account.account_id)).map(snapshotAccount),
    transactions: transactions.filter((transaction) => !removedAccounts.has(transaction.account_id)).map(snapshotTransaction),
    removed_account_ids: Array.from(removedAccounts)
  });
}

async function handleRemoveAccount(res, user, body) {
  const accountID = String(body.account_id || "").trim();
  if (!accountID) {
    return sendJson(res, 400, { ok: false, error: "account_id_required" });
  }

  await ensureSchema();
  const db = sql();
  const rows = await db`
    select a.account_id, a.item_id
    from accounts a
    join plaid_items i on i.item_id = a.item_id
    where a.account_id = ${accountID}
      and i.user_id = ${user.id}
    limit 1
  `;
  if (!rows[0]) {
    return sendJson(res, 404, { ok: false, error: "account_not_found_for_user" });
  }

  await db`
    insert into removed_accounts (user_id, account_id, item_id, removed_at)
    values (${user.id}, ${accountID}, ${rows[0].item_id}, now())
    on conflict (user_id, account_id)
    do update set item_id = excluded.item_id, removed_at = now()
  `;
  await db`delete from transactions where account_id = ${accountID}`;
  await db`delete from accounts where account_id = ${accountID}`;

  return sendJson(res, 200, { ok: true, user_id: user.id, account_id: accountID });
}

module.exports = async function handler(req, res) {
  if (req.method !== "POST") {
    return methodNotAllowed(res);
  }

  try {
    const user = await requireSupabaseUser(req);
    const body = await readJson(req);
    const route = routePath(req);

    if (route === "link/token/create") {
      return handleCreateLinkToken(req, res, user, body);
    }
    if (route === "link/token/get") {
      return handleGetLinkToken(res, body);
    }
    if (route === "item/public_token/exchange") {
      return handleExchangePublicToken(req, res, user, body);
    }
    if (route === "accounts/get") {
      return handleAccounts(res, user, body);
    }
    if (route === "transactions/sync") {
      return handleTransactionsSync(res, user, body);
    }
    if (route === "transactions/refresh") {
      return handleTransactionsRefresh(res, user, body);
    }
    if (route === "data/snapshot") {
      return handleSnapshot(res, user);
    }
    if (route === "accounts/remove") {
      return handleRemoveAccount(res, user, body);
    }

    return sendJson(res, 404, { ok: false, error: "unknown_plaid_backend_route", route });
  } catch (error) {
    return sendJson(res, error.statusCode || 500, { ok: false, error: error.message, plaid: error.payload });
  }
};
