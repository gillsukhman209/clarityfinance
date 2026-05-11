const { decrypt } = require("../_lib/crypto");
const { ensureSchema, sql } = require("../_lib/db");
const { methodNotAllowed, readJson, sendJson } = require("../_lib/http");
const { generateAndSendForDevice } = require("../_lib/notificationDelivery");
const { normalizePlaidTransaction, syncTransactions } = require("../_lib/plaid");

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

module.exports = async function handler(req, res) {
  if (req.method !== "POST") {
    return methodNotAllowed(res);
  }

  try {
    const body = await readJson(req);
    const webhookType = body.webhook_type;
    const webhookCode = body.webhook_code;
    const itemID = body.item_id;

    if (webhookType !== "TRANSACTIONS" || webhookCode !== "SYNC_UPDATES_AVAILABLE") {
      return sendJson(res, 200, { ok: true, ignored: true, webhook_type: webhookType, webhook_code: webhookCode });
    }

    if (!itemID) {
      return sendJson(res, 400, { ok: false, error: "item_id_required" });
    }

    await ensureSchema();
    const db = sql();
    const rows = await db`
      select
        plaid_items.*,
        devices.device_id,
        devices.apns_token,
        devices.enabled,
        devices.tone,
        devices.privacy
      from plaid_items
      join devices on devices.device_id = plaid_items.device_id
      where plaid_items.item_id = ${itemID}
      limit 1
    `;

    if (rows.length === 0) {
      return sendJson(res, 200, { ok: true, ignored: true, reason: "unregistered_item" });
    }

    const item = rows[0];
    const accessToken = decrypt(item.access_token_encrypted);
    const sync = await syncTransactions({
      accessToken,
      environment: item.environment,
      cursor: item.cursor
    });
    const added = sync.added.map((transaction) => normalizePlaidTransaction(transaction, itemID));
    const modified = sync.modified.map((transaction) => normalizePlaidTransaction(transaction, itemID));
    await upsertTransactions(db, itemID, [...added, ...modified]);

    for (const removed of sync.removed) {
      await db`delete from transactions where transaction_id = ${removed.transaction_id}`;
    }

    await db`
      update plaid_items
      set cursor = ${sync.nextCursor}, updated_at = now()
      where item_id = ${itemID}
    `;

    const delivery = await generateAndSendForDevice({
      db,
      device: item,
      itemID,
      newTransactions: added
    });

    return sendJson(res, 200, {
      ok: true,
      added: added.length,
      modified: modified.length,
      removed: sync.removed.length,
      delivery
    });
  } catch (error) {
    return sendJson(res, 500, { ok: false, error: error.message, plaid: error.payload });
  }
};
