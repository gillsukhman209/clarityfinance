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

function publicTokenMetadata(publicToken) {
  return {
    institutionID: publicToken?.institution_id || publicToken?.institutionID || null,
    institutionName: publicToken?.institution_name || publicToken?.institutionName || null
  };
}

async function createHostedLinkToken({ environment, userID, linkCustomizationName, webhookURL }) {
  const credentials = plaidCredentials(environment);
  const body = {
    client_id: credentials.clientID,
    secret: credentials.secret,
    client_name: "Clarity Finance",
    products: ["transactions"],
    country_codes: ["US"],
    language: "en",
    user: {
      client_user_id: userID
    },
    transactions: {
      days_requested: 730
    },
    hosted_link: {
      completion_redirect_uri: null,
      is_mobile_app: false,
      url_lifetime_seconds: 1800
    }
  };

  if (linkCustomizationName) {
    body.link_customization_name = linkCustomizationName;
  }

  if (webhookURL) {
    body.webhook = webhookURL;
  }

  return postPlaid(environment, "/link/token/create", body);
}

async function getLinkToken({ environment, linkToken }) {
  const credentials = plaidCredentials(environment);
  return postPlaid(environment, "/link/token/get", {
    client_id: credentials.clientID,
    secret: credentials.secret,
    link_token: linkToken
  });
}

async function exchangePublicToken({ environment, publicToken }) {
  const credentials = plaidCredentials(environment);
  return postPlaid(environment, "/item/public_token/exchange", {
    client_id: credentials.clientID,
    secret: credentials.secret,
    public_token: publicToken
  });
}

async function fetchAccounts({ accessToken, environment }) {
  const credentials = plaidCredentials(environment);
  return postPlaid(environment, "/accounts/get", {
    client_id: credentials.clientID,
    secret: credentials.secret,
    access_token: accessToken
  });
}

async function refreshTransactions({ accessToken, environment }) {
  const credentials = plaidCredentials(environment);
  return postPlaid(environment, "/transactions/refresh", {
    client_id: credentials.clientID,
    secret: credentials.secret,
    access_token: accessToken
  });
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
  createHostedLinkToken,
  exchangePublicToken,
  fetchAccounts,
  getLinkToken,
  normalizePlaidTransaction,
  publicTokenMetadata,
  refreshTransactions,
  syncTransactions,
  updateItemWebhook
};
