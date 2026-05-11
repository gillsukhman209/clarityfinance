function plaidBaseURL(environment) {
  return environment === "production"
    ? "https://production.plaid.com"
    : "https://sandbox.plaid.com";
}

function plaidSecret(environment) {
  if (environment === "production") {
    return process.env.PLAID_PRODUCTION_SECRET;
  }
  return process.env.PLAID_SANDBOX_SECRET;
}

function plaidCredentials(environment) {
  const clientID = process.env.PLAID_CLIENT_ID;
  const secret = plaidSecret(environment);
  if (!clientID || !secret) {
    throw new Error(`Plaid credentials are missing for ${environment}`);
  }
  return { clientID, secret };
}

async function postPlaid(environment, path, body) {
  const response = await fetch(`${plaidBaseURL(environment)}${path}`, {
    method: "POST",
    headers: {
      "content-type": "application/json"
    },
    body: JSON.stringify(body)
  });

  const payload = await response.json().catch(() => ({}));
  if (!response.ok) {
    const error = new Error(payload.error_message || payload.error_code || `Plaid ${path} failed`);
    error.payload = payload;
    throw error;
  }
  return payload;
}

async function updateItemWebhook({ accessToken, environment, webhookURL }) {
  const normalizedWebhookURL = String(webhookURL || "").trim();
  if (!normalizedWebhookURL) {
    return { skipped: true, reason: "PLAID_WEBHOOK_URL is missing" };
  }

  const credentials = plaidCredentials(environment);
  return postPlaid(environment, "/item/webhook/update", {
    client_id: credentials.clientID,
    secret: credentials.secret,
    access_token: accessToken,
    webhook: normalizedWebhookURL
  });
}

async function syncTransactions({ accessToken, environment, cursor }) {
  const credentials = plaidCredentials(environment);
  let nextCursor = cursor || null;
  let hasMore = true;
  const added = [];
  const modified = [];
  const removed = [];

  while (hasMore) {
    const payload = await postPlaid(environment, "/transactions/sync", {
      client_id: credentials.clientID,
      secret: credentials.secret,
      access_token: accessToken,
      cursor: nextCursor,
      count: 500,
      options: {
        days_requested: 730
      }
    });

    added.push(...(payload.added || []));
    modified.push(...(payload.modified || []));
    removed.push(...(payload.removed || []));
    nextCursor = payload.next_cursor || nextCursor;
    hasMore = Boolean(payload.has_more);
  }

  return {
    added,
    modified,
    removed,
    nextCursor
  };
}

function categoryFromPlaid(transaction) {
  const primary = transaction.personal_finance_category?.primary;
  if (primary) {
    return String(primary).toLowerCase();
  }

  return (transaction.category || []).join(" ").toLowerCase() || "other";
}

function normalizePlaidTransaction(transaction, itemID) {
  return {
    transactionId: transaction.transaction_id,
    itemId: itemID,
    accountId: transaction.account_id || null,
    merchantName: transaction.merchant_name || transaction.name || "Unknown",
    originalName: transaction.name || transaction.merchant_name || "Unknown",
    amount: Number(transaction.amount || 0),
    date: transaction.date,
    category: categoryFromPlaid(transaction),
    pending: Boolean(transaction.pending),
    source: "plaid",
    raw: transaction
  };
}

module.exports = {
  normalizePlaidTransaction,
  syncTransactions,
  updateItemWebhook
};
