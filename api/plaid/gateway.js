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

async function loadUserItem(db, userID, itemID) {
  const rows = await db`
    select access_token_encrypted, environment, cursor
    from plaid_items
    where item_id = ${itemID}
      and user_id = ${userID}
    limit 1
  `;
  return rows[0] || null;
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
  const normalized = [...sync.added, ...sync.modified].map((transaction) => normalizePlaidTransaction(transaction, itemID));
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
    added: sync.added,
    modified: sync.modified,
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

    return sendJson(res, 404, { ok: false, error: "unknown_plaid_backend_route", route });
  } catch (error) {
    return sendJson(res, error.statusCode || 500, { ok: false, error: error.message, plaid: error.payload });
  }
};
